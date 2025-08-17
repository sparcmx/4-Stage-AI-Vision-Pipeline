import os
import io
import sys
import yaml
import time
import boto3
import tempfile
import posixpath
from pathlib import Path
from typing import Dict, List

import mlflow
from ultralytics import YOLO

# ---------- ENV ----------
MLFLOW_TRACKING_URI = os.getenv("MLFLOW_TRACKING_URI", "http://mlflow:5000")
MLFLOW_S3_ENDPOINT_URL = os.getenv("MLFLOW_S3_ENDPOINT_URL", "http://minio:9000")
AWS_ACCESS_KEY_ID = os.getenv("AWS_ACCESS_KEY_ID", "minioadmin")
AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY", "minioadmin")

S3_DATA_BUCKET = os.getenv("S3_DATA_BUCKET", "datasets")
S3_MODELS_BUCKET = os.getenv("S3_MODELS_BUCKET", "models")

# Optional export flags
EXPORT_ONNX = os.getenv("EXPORT_ONNX", "1") == "1"
EXPORT_TRT  = os.getenv("EXPORT_TRT", "0") == "1"

# Local config (overridable)
STAGES_CFG = Path(os.getenv("STAGES_CFG", "/workspace/config/stages.yaml"))


# ---------- S3 UTILS ----------
def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=MLFLOW_S3_ENDPOINT_URL,
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    )

def _normalize_prefix(p: str) -> str:
    return p if p.endswith("/") else p + "/"

def s3_list(bucket: str, prefix: str) -> List[Dict]:
    cl = s3_client()
    token = None
    out = []
    while True:
        kw = dict(Bucket=bucket, Prefix=prefix)
        if token:
            kw["ContinuationToken"] = token
        resp = cl.list_objects_v2(**kw)
        for c in resp.get("Contents", []):
            out.append(c)
        if resp.get("IsTruncated"):
            token = resp.get("NextContinuationToken")
        else:
            break
    return out

def s3_download_prefix(bucket: str, prefix: str, dest_dir: Path):
    """Download all keys under s3://bucket/prefix into dest_dir, preserving layout."""
    cl = s3_client()
    prefix = _normalize_prefix(prefix)
    objects = s3_list(bucket, prefix)
    for obj in objects:
        key = obj["Key"]
        rel = key[len(prefix):] if key.startswith(prefix) else key
        rel = rel.lstrip("/")
        if not rel or rel.endswith("/"):
            continue
        out_path = dest_dir / rel
        out_path.parent.mkdir(parents=True, exist_ok=True)
        cl.download_file(bucket, key, str(out_path))

def s3_upload_file(local_path: Path, bucket: str, key: str):
    cl = s3_client()
    cl.upload_file(str(local_path), bucket, key)

def ensure_bucket(name: str):
    cl = s3_client()
    try:
        cl.head_bucket(Bucket=name)
    except Exception:
        cl.create_bucket(Bucket=name)


# ---------- TRAIN ONE STAGE ----------
def train_stage(stage_cfg: Dict, base_tmp: Path):
    """
    stage_cfg keys:
      name, s3_prefix, model, epochs, imgsz, batch
    """
    name = stage_cfg["name"]
    prefix = _normalize_prefix(stage_cfg["s3_prefix"])
    model_name = stage_cfg.get("model", "yolov8s.pt")
    epochs = int(stage_cfg.get("epochs", 40))
    imgsz = int(stage_cfg.get("imgsz", 960))
    batch = int(stage_cfg.get("batch", 16))

    stage_tmp = base_tmp / name
    stage_tmp.mkdir(parents=True, exist_ok=True)

    # 1) Sync dataset from MinIO -> local
    print(f"[{name}] Syncing dataset s3://{S3_DATA_BUCKET}/{prefix} -> {stage_tmp}")
    t0 = time.time()
    s3_download_prefix(S3_DATA_BUCKET, prefix, stage_tmp)
    print(f"[{name}] Sync complete in {time.time() - t0:.1f}s")

    ds_yaml = stage_tmp / "dataset.yaml"
    if not ds_yaml.exists():
        raise FileNotFoundError(f"[{name}] dataset.yaml not found in synced prefix")

    # 2) Optional: stage-specific hyperparams
    params_yaml = stage_tmp / "params.yaml"
    extra_args = {}
    if params_yaml.exists():
        with open(params_yaml, "r", encoding="utf-8") as f:
            hp = yaml.safe_load(f) or {}
        for k in ["lr0", "lrf", "momentum", "weight_decay", "warmup_epochs", "cos_lr"]:
            if k in hp:
                extra_args[k] = hp[k]

    # 3) Train
    print(f"[{name}] Training {model_name} for {epochs} epochs @ {imgsz}px, batch={batch}")
    model = YOLO(model_name)
    results = model.train(
        data=str(ds_yaml),
        epochs=epochs,
        imgsz=imgsz,
        batch=batch,
        project=str(stage_tmp / "runs"),
        name="train",
        **extra_args
    )

    # 4) Log metrics to MLflow
    metrics = results.results_dict or {}
    for k, v in metrics.items():
        try:
            mlflow.log_metric(f"{name}:{k}", float(v))
        except Exception:
            pass

    # 5) Upload best.pt to MinIO
    best_pt = stage_tmp / "runs" / "train" / "weights" / "best.pt"
    if best_pt.exists():
        dst = posixpath.join(name, "best.pt")
        s3_upload_file(best_pt, S3_MODELS_BUCKET, dst)
        mlflow.log_artifact(str(best_pt))
        print(f"[{name}] Uploaded weights to s3://{S3_MODELS_BUCKET}/{dst}")
    else:
        print(f"[{name}] WARNING: best.pt not found — training may have failed.")

    # 6) Optional exports
    exports = {}
    if EXPORT_ONNX and best_pt.exists():
        print(f"[{name}] Exporting ONNX…")
        model = YOLO(str(best_pt))
        onnx_path = model.export(format="onnx", imgsz=imgsz, opset=12, half=False)
        onnx_path = Path(onnx_path) if onnx_path else (stage_tmp / "runs" / "train" / "weights" / "best.onnx")
        if onnx_path.exists():
            onnx_key = posixpath.join(name, "best.onnx")
            s3_upload_file(onnx_path, S3_MODELS_BUCKET, onnx_key)
            mlflow.log_artifact(str(onnx_path))
            exports["onnx"] = onnx_key

    if EXPORT_TRT and best_pt.exists():
        print(f"[{name}] Exporting TensorRT…")
        model = YOLO(str(best_pt))
        trt_path = model.export(format="engine", imgsz=imgsz, half=False)
        trt_path = Path(trt_path) if trt_path else (stage_tmp / "runs" / "train" / "weights" / "best.engine")
        if trt_path.exists():
            trt_key = posixpath.join(name, "best.engine")
            s3_upload_file(trt_path, S3_MODELS_BUCKET, trt_key)
            mlflow.log_artifact(str(trt_path))
            exports["trt"] = trt_key

    return {
        "stage": name,
        "metrics": metrics,
        "exports": exports
    }


def main():
    mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)
    mlflow.set_experiment("YOLOv8 Multistage Vehicle/Driver/Phone/Seatbelt")

    ensure_bucket(S3_DATA_BUCKET)
    ensure_bucket(S3_MODELS_BUCKET)

    with open(STAGES_CFG, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    stages = cfg.get("stages", [])
    if not stages:
        print("No stages declared in stages.yaml — nothing to do.")
        sys.exit(1)

    with mlflow.start_run(run_name="multistage"):
        mlflow.log_param("num_stages", len(stages))
        with tempfile.TemporaryDirectory() as tmp_root:
            tmp_root = Path(tmp_root)
            results = []
            for stage in stages:
                name = stage["name"]
                with mlflow.start_run(run_name=name, nested=True):
                    for k in ("model", "epochs", "imgsz", "batch"):
                        if k in stage:
                            mlflow.log_param(f"{name}:{k}", stage[k])
                    res = train_stage(stage, base_tmp=tmp_root)
                    results.append(res)

        for r in results:
            stage = r["stage"]
            for metric_key in ("metrics/mAP50-95(B)", "metrics/mAP50(B)", "metrics/precision(B)", "metrics/recall(B)"):
                v = r["metrics"].get(metric_key)
                if v is not None:
                    mlflow.log_metric(f"{stage}:{metric_key}", float(v))

    print("✅ Multistage training complete.")


if __name__ == "__main__":
    main()

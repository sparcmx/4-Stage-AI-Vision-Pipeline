# 4-Stage AI Vision Pipeline
Spin up a full, local, multi‑stage detection pipeline in minutes: MinIO (S3), CVAT, MLflow, Triton Inference Server, and Evidently. Windows‑first with PowerShell scripts, but Docker makes it portable.

> Primary goal: a **self‑installing** YOLOv8 multi‑stage training + serving stack (originally for Mobile Phone + Seatbelt detection) that you can retarget to other objects with minimal edits.

---

## TL;DR (Quick Start)

**Prereqs**

* Windows 10/11 + Docker Desktop (WSL2 backend recommended)
* PowerShell (5.1+ or PowerShell 7), Git
* AWS CLI v2 (used to talk to MinIO’s S3 API)
* Optional: NVIDIA GPU + drivers + CUDA container runtime

**Boot the stack**

```bat
# From repo root on Windows
prime.cmd
```

This builds the trainer image (`yolo-trainer/Dockerfile`) and runs `prime.ps1`, which:

* `docker compose up -d` the services
* waits for health endpoints to come up
* optionally runs bootstrap scripts (if present)

**Open the UIs**

* MinIO: [http://localhost:9001](http://localhost:9001) (console) | S3: [http://localhost:9000](http://localhost:9000)
  Default creds: `minioadmin` / `minioadmin`
* CVAT: [http://localhost:8080](http://localhost:8080) -- I need to find a new pull source for CVAT, current is problematic.
* MLflow: [http://localhost:5000](http://localhost:5000)
* Triton: [http://localhost:8000](http://localhost:8000) (HTTP), :8001 (gRPC)
* Evidently: [http://localhost:8008](http://localhost:8008)

Stop everything: `docker compose down`

---

## What comes up (services & ports)

> The compose file provisions the core MLOps services. Exact images/tags can be tweaked in `docker-compose.yml`.

| Service                 | Purpose                                            | Default Ports             |
| ----------------------- | -------------------------------------------------- | ------------------------- |
| MinIO                   | S3‑compatible object store for datasets and models | 9000 (S3), 9001 (console) |
| CVAT + Postgres + Redis | Image/video labeling and exports                   | 8080 (UI)                 |
| MLflow                  | Experiment tracking & artifacts                    | 5000                      |
| Triton Inference Server | Model serving (ONNX, TensorRT…)                    | 8000 (HTTP), 8001 (gRPC)  |
| Evidently               | Data & drift monitoring service                    | 8008                      |

Networks/volumes are created automatically by compose. Default MinIO buckets used by scripts: `datasets`, `models`.

---

## Repo scripts (automation)

All scripts are idempotent and safe to re‑run.

* **`prime.cmd`**
  Builds the YOLO trainer image from `yolo-trainer/Dockerfile`, then runs `prime.ps1` with ExecutionPolicy bypass.

* **`prime.ps1`**
  Orchestrates `docker compose up`, waits for health (MinIO, CVAT, MLflow, Triton, Evidently), and optionally runs the bootstrap scripts (if found). Key params:

  ```powershell
  .\prime.ps1 -ComposeFile .\docker-compose.yml -TrainerDir .\yolo-trainer \
               -MinioEndpoint http://localhost:9000 -MlflowEndpoint http://localhost:5000 \
               -AccessKey minioadmin -SecretKey minioadmin -WaitTimeoutSec 120
  ```

* **`init-minio.ps1`**
  Ensures required buckets exist in MinIO:

  ```powershell
  .\init-minio.ps1 -Endpoint http://minio:9000 -AccessKey minioadmin -SecretKey minioadmin
  # creates: datasets, models
  ```

* **`bootstrap-stage.ps1`**
  Pushes a single **stage’s** dataset and params to MinIO, under a prefix.

  * Expects `dataset.yaml` (YOLO format) and optional `params.yaml` next to images/labels.
  * Copies everything to `s3://datasets/<StageName>/...`

  ```powershell
  .\bootstrap-stage.ps1 -StageName phone \
    -DatasetPath .\data\phone\dataset.yaml \
    -ParamsPath  .\data\phone\params.yaml \
    -Bucket datasets -Endpoint http://localhost:9000 \
    -AccessKey minioadmin -SecretKey minioadmin
  ```

* **`push-to-minio.ps1`**
  Generic folder sync to MinIO bucket/prefix.

* **`start-training.ps1`**
  Runs the trainer container for **multi‑stage** training, wiring MLflow and MinIO via env vars.

  ```powershell
  .\start-training.ps1 -ConfigPath .\stages.yaml \
    -ImageName mlops-pipeline-yolo-trainer \
    -MLflowUri http://mlflow:5000 -S3Endpoint http://minio:9000 \
    -Network mlops
  ```

  By default it looks for `./stages.yaml` and uses MinIO buckets `datasets` and `models`.

* **`export-to-triton.ps1`**
  Fetches a stage’s `best.onnx` from MinIO `models` bucket, ready to drop into your Triton model repo.

> Note: `prime.ps1` will auto‑run `init-minio.ps1` and `bootstrap-stage.ps1` if present. Placement can be root or `./scripts/`.

---

## Reference workflow

1. **Label data in CVAT**
   Export in YOLO format (images + `labels/` + `dataset.yaml`).

2. **Bootstrap a stage to MinIO**

   ```powershell
   .\bootstrap-stage.ps1 -StageName vehicle -DatasetPath .\data\vehicle\dataset.yaml -ParamsPath .\data\vehicle\params.yaml
   ```

   This mirrors the dataset to `s3://datasets/vehicle/...` and uploads the stage’s `dataset.yaml` and `params.yaml` at the prefix root.

3. **Define stages**
   Create `stages.yaml` in repo root describing the multi‑stage cascade (examples below).

4. **Train**

   ```powershell
   .\start-training.ps1 -ConfigPath .\stages.yaml -ImageName mlops-pipeline-yolo-trainer -Network mlops
   ```

   MLflow UI shows runs, params, metrics and artifacts at `http://localhost:5000`.

5. **Serve**
   Use `export-to-triton.ps1` to pull the best ONNX per stage, then place in Triton’s model repository. Restart or hot‑reload Triton.

6. **Monitor**
   Send inference data to Evidently for drift/quality dashboards.

---

## Retargeting beyond Phone/Seatbelt

The system is object‑agnostic. To detect anything else (helmets, vests, logos, defects):

1. **Make a stage per sub‑task**
   For a three‑stage example: `vehicle` → `driver` → `helmet`.

2. **Put each stage’s dataset in MinIO** using `bootstrap-stage.ps1`.

3. **Describe the pipeline in `stages.yaml`**
   Minimal example:

   ```yaml
   stages:
     - name: vehicle
       data:
         bucket: datasets
         prefix: vehicle/
       params:
         epochs: 50
         imgsz: 1280
         batch: 8
         classes: ["car","truck","bus"]

     - name: driver
       depends_on: vehicle
       crop_from: vehicle  # trainer crops next inputs from previous detections
       data:
         bucket: datasets
         prefix: driver/
       params:
         epochs: 60
         imgsz: 1024

     - name: helmet
       depends_on: driver
       crop_from: driver
       data:
         bucket: datasets
         prefix: helmet/
       params:
         epochs: 80
         imgsz: 960
   ```

4. **Stage dataset layout**
   Each stage should have YOLO‑style dirs and a `dataset.yaml`:

   ```yaml
   # data/<stage>/dataset.yaml
   path: .
   train: images/train
   val: images/val
   test: images/test  # optional
   names: ["class0","class1", "class2"]
   ```

   Optional `params.yaml` lives beside it, anything you want the trainer to pick up (augmentations, lr, schedulers). Example:

   ```yaml
   epochs: 80
   imgsz: 1280
   batch: 8
   lr0: 0.01
   mosaic: 0.5
   hsv_h: 0.015
   ```

5. **Upload** with `bootstrap-stage.ps1` and update `stages.yaml` to point to the right prefixes.

6. **Train again** and redeploy.

---

## Configuration knobs

* **Credentials**
  Most scripts default to `minioadmin`/`minioadmin`. Override with flags.

* **GPU/CPU**
  Use GPU‑enabled trainer/Triton images if available. Compose can be extended with `deploy.resources.reservations.devices` or `--gpus all` depending on your setup.

* **Buckets/paths**
  Change bucket names via script args. Prefixes default to the stage name.

* **Trainer image name**
  `prime.cmd` builds `mlops-pipeline-yolo-trainer`. Pass `-ImageName mlops-pipeline-yolo-trainer` to `start-training.ps1` if your default differs.

---

## Troubleshooting

* Ports already in use: change mappings in `docker-compose.yml`.
* AWS CLI not found: install AWS CLI v2 and re‑open your terminal.
* MinIO auth failures: verify access/secret keys; the scripts use a local `minio` profile.
* Triton health: check `http://localhost:8000/v2/health/ready`.
* CVAT export issues: prefer **YOLO** exports; ensure label names match your classes.
* WSL2 memory/CPU: tune Docker Desktop resources if builds or training stall.

---

## Clean up

```powershell
# Stop services
docker compose down
# Remove named volumes if you want a fresh slate (this deletes data!)
docker volume ls | where { $_.Name -match "(minio|cvat)" } | foreach { docker volume rm $_.Name }
```

---

## License
MIT.

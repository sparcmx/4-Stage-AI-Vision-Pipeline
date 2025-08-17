# GPU base
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y python3-pip git ffmpeg libgl1 wget && rm -rf /var/lib/apt/lists/*
RUN python3 -m pip install --upgrade pip

# PyTorch w/ CUDA 12.1
RUN pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Training stack
RUN pip install ultralytics mlflow boto3 opencv-python-headless pycocotools onnx onnxsim onnxruntime-gpu tqdm

# Optional: MinIO client (mc) for convenience
RUN wget -qO /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x /usr/local/bin/mc

WORKDIR /workspace
ENV PYTHONUNBUFFERED=1

# Default to running training (compose still overrides if needed)
CMD ["python","/workspace/train.py"]

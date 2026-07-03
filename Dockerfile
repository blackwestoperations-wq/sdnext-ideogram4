FROM pytorch/pytorch:2.9.0-cuda12.8-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV HF_HUB_ENABLE_HF_TRANSFER=1

WORKDIR /app

RUN apt-get update && apt-get install -y \
    git \
    git-lfs \
    curl \
    wget \
    unzip \
    ffmpeg \
    build-essential \
    rsync \
    ca-certificates \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxrender1 \
    libxext6 \
    fuse \
 && rm -rf /var/lib/apt/lists/*

RUN git lfs install

RUN curl https://rclone.org/install.sh | bash

RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

RUN python -m pip install --upgrade pip setuptools wheel

RUN pip install -r requirements.txt

RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git \
    custom_nodes/ComfyUI-Manager

RUN pip install \
    -r custom_nodes/ComfyUI-Manager/requirements.txt

RUN pip install \
    huggingface_hub \
    hf_transfer

RUN mkdir -p \
    /workspace/models \
    /workspace/custom_nodes \
    /workspace/user \
    /workspace/input \
    /workspace/output \
    /workspace/workflows

COPY entrypoint.sh /entrypoint.sh
COPY extra_model_paths.yaml /workspace/extra_model_paths.yaml

RUN chmod +x /entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/entrypoint.sh"]

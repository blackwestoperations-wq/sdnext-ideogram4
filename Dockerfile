FROM pytorch/pytorch:2.9.0-cuda12.8-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
# Replaced deprecated HF_HUB_ENABLE_HF_TRANSFER
ENV HF_XET_HIGH_PERFORMANCE=1

WORKDIR /app

# Install system dependencies including fuse and kmod
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
    kmod \
 && rm -rf /var/lib/apt/lists/*

# Allow non-root access to FUSE mounts (required for rclone --allow-other)
RUN sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

RUN git lfs install

# Install rclone
RUN curl https://rclone.org/install.sh | bash

# Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# Install Python dependencies
RUN python -m pip install --upgrade pip setuptools wheel
RUN pip install -r requirements.txt

# Install ComfyUI-Manager
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager
RUN pip install -r custom_nodes/ComfyUI-Manager/requirements.txt

# Install huggingface_hub
RUN pip install huggingface_hub

# Create workspace directories
RUN mkdir -p /workspace/models /workspace/custom_nodes /workspace/user /workspace/input /workspace/output /workspace/workflows

# Copy entrypoint and config
COPY entrypoint.sh /entrypoint.sh
COPY extra_model_paths.yaml /workspace/extra_model_paths.yaml

RUN chmod +x /entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/entrypoint.sh"]

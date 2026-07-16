FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04

################################################################################
# Environment
################################################################################

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    CC=/usr/bin/gcc \
    CXX=/usr/bin/g++ \
    ALLOW_GIT_URL_INSTALL=1 \
    COMFYUI_PATH=/app/ComfyUI \
    HF_HOME=/app/cache/huggingface \
    TORCH_HOME=/app/cache/torch

################################################################################
# System packages
################################################################################

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    git \
    curl \
    wget \
    ca-certificates \
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    ninja-build \
    pkg-config \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
 && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip setuptools wheel

################################################################################
# ComfyUI
################################################################################

WORKDIR /app

RUN git clone \
    --depth 1 \
    https://github.com/comfyanonymous/ComfyUI.git \
    /app/ComfyUI

################################################################################
# PyTorch
################################################################################

RUN pip3 install \
    torch \
    torchvision \
    torchaudio \
    --index-url https://download.pytorch.org/whl/cu128

################################################################################
# Python dependencies
################################################################################

RUN pip3 install -r /app/ComfyUI/requirements.txt

################################################################################
# ComfyUI Manager
################################################################################

RUN git clone \
    --depth 1 \
    https://github.com/ltdrdata/ComfyUI-Manager.git \
    /app/ComfyUI/custom_nodes/ComfyUI-Manager

RUN pip3 install \
    -r /app/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt

################################################################################
# Manager config
################################################################################

COPY manager_config.ini \
/app/ComfyUI/custom_nodes/ComfyUI-Manager/config.ini

################################################################################
# Directories
################################################################################

RUN mkdir -p \
/app/cache \
/app/ComfyUI/input \
/app/ComfyUI/output \
/app/ComfyUI/temp \
/app/ComfyUI/models/checkpoints \
/app/ComfyUI/models/clip \
/app/ComfyUI/models/clip_vision \
/app/ComfyUI/models/controlnet \
/app/ComfyUI/models/diffusers \
/app/ComfyUI/models/embeddings \
/app/ComfyUI/models/loras \
/app/ComfyUI/models/upscale_models \
/app/ComfyUI/models/unet \
/app/ComfyUI/models/vae

################################################################################
# Verify compiler exists
################################################################################

RUN gcc --version
RUN g++ --version

################################################################################
# Startup
################################################################################

COPY start.sh /start.sh

RUN chmod +x /start.sh

WORKDIR /app/ComfyUI

EXPOSE 8188

ENTRYPOINT ["/start.sh"]

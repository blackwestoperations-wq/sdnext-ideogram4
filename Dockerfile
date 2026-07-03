# =============================================================================
# ComfyUI + ComfyUI Manager
# Koyeb GPU + DigitalOcean Spaces
# =============================================================================

FROM pytorch/pytorch:2.9.0-cuda12.8-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

WORKDIR /app

# =============================================================================
# System Dependencies
# =============================================================================

RUN apt-get update && apt-get install -y \
    git \
    git-lfs \
    curl \
    wget \
    unzip \
    ffmpeg \
    build-essential \
    ca-certificates \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxrender1 \
    libxext6 \
    fuse \
    && rm -rf /var/lib/apt/lists/*

RUN git lfs install

# =============================================================================
# Install rclone
# =============================================================================

RUN curl https://rclone.org/install.sh | bash

# =============================================================================
# Clone latest ComfyUI
# =============================================================================

RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# =============================================================================
# Python
# =============================================================================

RUN python -m pip install --upgrade \
    pip \
    setuptools \
    wheel

# =============================================================================
# ComfyUI Requirements
# =============================================================================

RUN pip install -r requirements.txt

# =============================================================================
# ComfyUI Manager
# =============================================================================

RUN git clone \
    https://github.com/ltdrdata/ComfyUI-Manager.git \
    custom_nodes/ComfyUI-Manager

RUN pip install \
    -r custom_nodes/ComfyUI-Manager/requirements.txt

# =============================================================================
# HuggingFace + Download Utilities
# =============================================================================

RUN pip install \
    huggingface_hub \
    hf_transfer

ENV HF_HUB_ENABLE_HF_TRANSFER=1

# =============================================================================
# Persistent Workspace
# =============================================================================

RUN mkdir -p \
    /workspace/models/checkpoints \
    /workspace/models/diffusion_models \
    /workspace/models/text_encoders \
    /workspace/models/vae \
    /workspace/models/vae_approx \
    /workspace/models/clip \
    /workspace/models/clip_vision \
    /workspace/models/controlnet \
    /workspace/models/embeddings \
    /workspace/models/gligen \
    /workspace/models/hypernetworks \
    /workspace/models/loras \
    /workspace/models/style_models \
    /workspace/models/unet \
    /workspace/models/upscale_models \
    /workspace/custom_nodes \
    /workspace/input \
    /workspace/output \
    /workspace/user \
    /workspace/workflows \
    /workspace/configs \
    /workspace/cache

# =============================================================================
# Copy Startup Files
# =============================================================================

COPY entrypoint.sh /entrypoint.sh
COPY extra_model_paths.yaml /workspace/extra_model_paths.yaml

RUN chmod +x /entrypoint.sh

# =============================================================================
# Expose ComfyUI
# =============================================================================

EXPOSE 8188

ENTRYPOINT ["/entrypoint.sh"]

FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# ── Environment ────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    # ComfyUI Manager: allow installing nodes from raw git URLs
    ALLOW_GIT_URL_INSTALL=1 \
    COMFYUI_PATH=/app/ComfyUI

# ── System dependencies ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    git \
    wget \
    curl \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── ComfyUI ────────────────────────────────────────────────────────────────
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /app/ComfyUI

# PyTorch with CUDA 12.1 — pin versions for reproducible builds
RUN pip3 install \
    torch==2.3.1+cu121 \
    torchvision==0.18.1+cu121 \
    torchaudio==2.3.1+cu121 \
    --index-url https://download.pytorch.org/whl/cu121

RUN pip3 install -r /app/ComfyUI/requirements.txt

# ── ComfyUI Manager ────────────────────────────────────────────────────────
RUN git clone --depth 1 \
    https://github.com/ltdrdata/ComfyUI-Manager.git \
    /app/ComfyUI/custom_nodes/ComfyUI-Manager

RUN pip3 install -r /app/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt

# ── Manager config: security = weak ───────────────────────────────────────
COPY manager_config.ini \
     /app/ComfyUI/custom_nodes/ComfyUI-Manager/config.ini

# ── Model & output directories ─────────────────────────────────────────────
RUN mkdir -p \
    /app/ComfyUI/models/checkpoints \
    /app/ComfyUI/models/clip \
    /app/ComfyUI/models/clip_vision \
    /app/ComfyUI/models/controlnet \
    /app/ComfyUI/models/diffusers \
    /app/ComfyUI/models/embeddings \
    /app/ComfyUI/models/loras \
    /app/ComfyUI/models/upscale_models \
    /app/ComfyUI/models/vae \
    /app/ComfyUI/output \
    /app/ComfyUI/input \
    /app/ComfyUI/temp

# ── Startup ────────────────────────────────────────────────────────────────
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188

CMD ["/start.sh"]

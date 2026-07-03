FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# System dependencies
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-dev \
    git wget curl aria2 \
    libgl1 libglib2.0-0 libsm6 libxrender1 libxext6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /app

# Install PyTorch — cu118 has the widest NVIDIA driver compatibility
# Supports drivers as old as 450.x, covers all Koyeb GPU instances
RUN pip3 install --no-cache-dir \
    torch==2.3.1 torchvision==0.18.1 torchaudio==2.3.1 \
    --index-url https://download.pytorch.org/whl/cu118

# Install ComfyUI Python dependencies
RUN pip3 install --no-cache-dir -r /app/requirements.txt

# Install ComfyUI-Manager
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git \
    /app/custom_nodes/ComfyUI-Manager \
    && pip3 install --no-cache-dir \
    -r /app/custom_nodes/ComfyUI-Manager/requirements.txt

# Install download tools
RUN pip3 install --no-cache-dir huggingface_hub hf_transfer

# Pre-create all model directories ComfyUI expects
RUN mkdir -p \
    /app/models/checkpoints \
    /app/models/diffusion_models \
    /app/models/text_encoders \
    /app/models/vae \
    /app/models/loras \
    /app/models/controlnet \
    /app/models/unet \
    /app/models/clip \
    /app/output \
    /app/input

COPY entrypoint.sh /app/entrypoint.sh
COPY models.txt /app/models.txt
RUN chmod +x /app/entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/app/entrypoint.sh"]

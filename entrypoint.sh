#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/workspace"
REMOTE="dospaces"

echo "=========================================="
echo "ComfyUI + DigitalOcean Spaces (STABLE MODE)"
echo "=========================================="

# -----------------------------
# GPU CHECK
# -----------------------------
python - <<EOF
import torch
print("PyTorch:", torch.__version__)
print("CUDA Available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
EOF

# -----------------------------
# RCLONE CONFIG
# -----------------------------
mkdir -p /root/.config/rclone

cat >/root/.config/rclone/rclone.conf <<EOF
[$REMOTE]
type = s3
provider = DigitalOcean
env_auth = false
access_key_id = ${AWS_ACCESS_KEY_ID}
secret_access_key = ${AWS_SECRET_ACCESS_KEY}
endpoint = ams3.digitaloceanspaces.com
region = ${AWS_DEFAULT_REGION}
acl = private
EOF

# -----------------------------
# WORKSPACE SETUP
# -----------------------------
mkdir -p ${WORKSPACE}/{models,custom_nodes,user,input,output,workflows}

# -----------------------------
# CLEAN PARTIAL FILES (SAFE)
# -----------------------------
echo "Cleaning stale partial files..."
rclone delete ${REMOTE}:${SPACES_BUCKET} \
  --include "*.partial" \
  --include "*.tmp" \
  --s3-no-check-bucket \
  || true

# -----------------------------
# BOOTSTRAP DOWNLOAD (ONE-TIME SAFE SYNC)
# -----------------------------
echo "Downloading workspace (BOOT STRAP ONLY)..."

if rclone lsd ${REMOTE}:${SPACES_BUCKET} --s3-no-check-bucket >/dev/null 2>&1; then
    rclone copy \
        ${REMOTE}:${SPACES_BUCKET} \
        ${WORKSPACE} \
        --fast-list \
        --transfers 8 \
        --checkers 8 \
        --s3-no-check-bucket \
        --temp-dir /tmp \
        --exclude "*.partial" \
        --exclude "*.tmp" \
        --log-level INFO
fi

# -----------------------------
# SYMBOLIC LINKS (COMFYUI EXPECTED PATHS)
# -----------------------------
ln -sfn ${WORKSPACE}/models /app/models
ln -sfn ${WORKSPACE}/custom_nodes /app/custom_nodes
ln -sfn ${WORKSPACE}/user /app/user
ln -sfn ${WORKSPACE}/output /app/output
ln -sfn ${WORKSPACE}/input /app/input

# -----------------------------
# COMFYUI MANAGER (SAFE INSTALL)
# -----------------------------
if [ ! -d /app/custom_nodes/ComfyUI-Manager ]; then
    echo "Installing ComfyUI-Manager..."
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git \
        /app/custom_nodes/ComfyUI-Manager

    pip install -r /app/custom_nodes/ComfyUI-Manager/requirements.txt
fi

# -----------------------------
# OUTPUT SYNC WORKER (SAFE ONE-WAY)
# -----------------------------
echo "Starting background output sync..."

sync_outputs () {
    while true; do
        sleep 60

        echo "[SYNC] Uploading outputs..."

        rclone copy \
            ${WORKSPACE}/output \
            ${REMOTE}:${SPACES_BUCKET}/output \
            --fast-list \
            --transfers 4 \
            --checkers 4 \
            --s3-no-check-bucket \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            --min-age 10s \
            --log-level ERROR || true
    done
}

sync_outputs &

# -----------------------------
# START COMFYUI
# -----------------------------
echo "Starting ComfyUI..."

exec python /app/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --extra-model-paths-config /workspace/extra_model_paths.yaml

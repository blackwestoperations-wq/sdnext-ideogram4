#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/workspace"
REMOTE="dospaces"

echo "=========================================="
echo "ComfyUI + Spaces (NO-MOVE SAFE MODE)"
echo "=========================================="

python - <<EOF
import torch
print("PyTorch:", torch.__version__)
print("CUDA:", torch.cuda.is_available())
if torch.cuda.is_available():
    print(torch.cuda.get_device_name(0))
EOF

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

mkdir -p ${WORKSPACE}/{models,custom_nodes,user,input,output,workflows}

echo "BOOT: Downloading static assets only (NO SYNC BACK)..."

# ⚠️ IMPORTANT: only pull stable assets, never full bucket
rclone copy \
    ${REMOTE}:${SPACES_BUCKET}/models \
    ${WORKSPACE}/models \
    --transfers 4 \
    --checkers 4 \
    --s3-no-check-bucket \
    --ignore-existing \
    --exclude "*.partial" \
    --log-level INFO || true

rclone copy \
    ${REMOTE}:${SPACES_BUCKET}/workflows \
    ${WORKSPACE}/workflows \
    --transfers 4 \
    --checkers 4 \
    --s3-no-check-bucket \
    --ignore-existing \
    --exclude "*.partial" \
    --log-level INFO || true

echo "Linking ComfyUI paths..."

ln -sfn ${WORKSPACE}/models /app/models
ln -sfn ${WORKSPACE}/custom_nodes /app/custom_nodes
ln -sfn ${WORKSPACE}/user /app/user
ln -sfn ${WORKSPACE}/output /app/output
ln -sfn ${WORKSPACE}/input /app/input

# -----------------------------
# SAFE OUTPUT UPLOADER ONLY
# -----------------------------
sync_outputs () {
    while true; do
        sleep 60

        echo "[UPLOAD] outputs only..."

        rclone copy \
            ${WORKSPACE}/output \
            ${REMOTE}:${SPACES_BUCKET}/output \
            --transfers 2 \
            --checkers 2 \
            --s3-no-check-bucket \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            --log-level ERROR || true
    done
}

sync_outputs &

echo "Starting ComfyUI..."

exec python /app/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --extra-model-paths-config /workspace/extra_model_paths.yaml

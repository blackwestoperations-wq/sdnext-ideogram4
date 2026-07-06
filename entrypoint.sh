#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/workspace"
REMOTE="dospaces"
RCLONE_FLAGS="--inplace --s3-no-check-bucket --transfers 6 --checkers 8 --retries 3 --low-level-retries 5"

echo "=========================================="
echo "ComfyUI + Spaces (Privileged Lazy Mount)"
echo "=========================================="

python - <<EOF
import torch
print("PyTorch:", torch.__version__)
print("CUDA:", torch.cuda.is_available())
if torch.cuda.is_available():
    print(torch.cuda.get_device_name(0))
EOF

# ---------------------------------------------------
# Configure rclone
# ---------------------------------------------------
mkdir -p /root/.config/rclone

cat >/root/.config/rclone/rclone.conf <<EOF
[$REMOTE]
type = s3
provider = DigitalOcean
env_auth = false
access_key_id = ${AWS_ACCESS_KEY_ID}
secret_access_key = ${AWS_SECRET_ACCESS_KEY}
endpoint = ${SPACES_ENDPOINT:-ams3.digitaloceanspaces.com}
region = ${AWS_DEFAULT_REGION}
acl = private
EOF

# ---------------------------------------------------
# Workspace setup
# ---------------------------------------------------
mkdir -p \
    ${WORKSPACE}/models \
    ${WORKSPACE}/custom_nodes \
    ${WORKSPACE}/user \
    ${WORKSPACE}/input \
    ${WORKSPACE}/output \
    ${WORKSPACE}/workflows

# ---------------------------------------------------
# Mount models from Spaces (Lazy Loading via FUSE)
# ---------------------------------------------------
echo "BOOT: Checking for FUSE device..."

# Check if /dev/fuse exists (Koyeb might not expose it)
if [ -e /dev/fuse ]; then
    echo "BOOT: /dev/fuse found. Attempting to mount models from Spaces..."
    modprobe fuse 2>/dev/null || true
    
    # Try to mount the bucket
    rclone mount \
        ${REMOTE}:${SPACES_BUCKET}/models \
        ${WORKSPACE}/models \
        --vfs-cache-mode full \
        --vfs-cache-max-size 50G \
        --vfs-cache-max-age 168h \
        --dir-cache-time 1m \
        --attr-timeout 30s \
        --buffer-size 512M \
        --daemon \
        --daemon-wait 5s \
        --allow-other \
        --s3-no-check-bucket \
        --umask 022 \
        2>/dev/null || true

    # Check if mount actually succeeded
    sleep 2
    if mountpoint -q ${WORKSPACE}/models; then
        echo "✅ Models mounted successfully (lazy loading enabled). Writes will sync to Spaces."
    else
        echo "⚠️ Mount failed, falling back to rclone copy..."
        rclone copy \
            ${REMOTE}:${SPACES_BUCKET}/models \
            ${WORKSPACE}/models \
            ${RCLONE_FLAGS} \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            || true
    fi
else
    echo "⚠️ /dev/fuse not found. Falling back to rclone copy..."
    rclone copy \
        ${REMOTE}:${SPACES_BUCKET}/models \
        ${WORKSPACE}/models \
        ${RCLONE_FLAGS} \
        --ignore-existing \
        --exclude "*.partial" \
        --exclude "*.tmp" \
        || true
fi

# ---------------------------------------------------
# Sync other directories (Standard Copy)
# ---------------------------------------------------
echo "BOOT: Syncing workflows..."
rclone copy ${REMOTE}:${SPACES_BUCKET}/workflows ${WORKSPACE}/workflows ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" || true

echo "BOOT: Syncing user data..."
rclone copy ${REMOTE}:${SPACES_BUCKET}/user ${WORKSPACE}/user ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" || true

echo "BOOT: Syncing custom_nodes..."
rclone copy ${REMOTE}:${SPACES_BUCKET}/custom_nodes ${WORKSPACE}/custom_nodes ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" --exclude "__pycache__/**" --exclude "*.pyc" || true

# Install requirements for custom nodes
if [ -d "${WORKSPACE}/custom_nodes" ]; then
    for req in ${WORKSPACE}/custom_nodes/*/requirements.txt; do
        if [ -f "$req" ]; then
            node_name=$(basename $(dirname "$req"))
            echo "  Installing deps for: ${node_name}"
            pip install -r "$req" --quiet || echo "  WARN: failed deps for ${node_name}"
        fi
    done
fi

# ---------------------------------------------------
# Link workspace into ComfyUI app directory
# ---------------------------------------------------
for dir in models input output user; do
    rm -rf /app/${dir}
    ln -s ${WORKSPACE}/${dir} /app/${dir}
done

# Merge custom_nodes
mkdir -p /app/custom_nodes
if [ -d "${WORKSPACE}/custom_nodes" ]; then
    for node_dir in ${WORKSPACE}/custom_nodes/*/; do
        node_name=$(basename "$node_dir")
        if [ "$node_name" != "*" ] && [ ! -L "/app/custom_nodes/${node_name}" ]; then
            ln -s "${node_dir}" "/app/custom_nodes/${node_name}"
        fi
    done
fi

# Ensure built-in ComfyUI-Manager is linked if missing
if [ ! -d "/app/custom_nodes/ComfyUI-Manager" ]; then
    ln -s /app/custom_nodes/ComfyUI-Manager /app/custom_nodes/ComfyUI-Manager 2>/dev/null || true
fi
mkdir -p /app/user/__manager

# ---------------------------------------------------
# ComfyUI Manager Configuration
# ---------------------------------------------------
CONFIG_CONTENT='[default]
security_level = weak
allow_git_url_install = true
network_mode = public
update_policy = stable
skip_migration_check = true
'

for DIR in /app/user/__manager /app/user/default/ComfyUI-Manager /app/user/ComfyUI-Manager; do
    mkdir -p "$DIR"
    echo "$CONFIG_CONTENT" > "$DIR/config.ini"
done

# ---------------------------------------------------
# Background sync: Upload outputs, custom_nodes, workflows, user
# ---------------------------------------------------
sync_to_spaces() {
    while true; do
        sleep 120
        
        echo "[SYNC] Uploading outputs..."
        rclone copy ${WORKSPACE}/output ${REMOTE}:${SPACES_BUCKET}/output ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" --exclude "*.tmp" --log-level ERROR || true
        
        echo "[SYNC] Uploading custom_nodes..."
        rclone copy /app/custom_nodes ${REMOTE}:${SPACES_BUCKET}/custom_nodes ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" --exclude "__pycache__/**" --exclude "*.pyc" --exclude "*/.git/**" --log-level ERROR || true
        
        echo "[SYNC] Uploading user settings..."
        rclone copy ${WORKSPACE}/user ${REMOTE}:${SPACES_BUCKET}/user ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" --log-level ERROR || true

        # If models mount failed, we fallback to copying models here
        if ! mountpoint -q ${WORKSPACE}/models 2>/dev/null; then
            echo "[SYNC] Uploading new models (fallback mode)..."
            rclone copy ${WORKSPACE}/models ${REMOTE}:${SPACES_BUCKET}/models ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" --exclude "*.tmp" --log-level ERROR || true
        fi

    done
}
sync_to_spaces &

# ---------------------------------------------------
# Start ComfyUI
# ---------------------------------------------------
echo "=========================================="
echo "Starting ComfyUI..."
echo "=========================================="
exec python /app/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --extra-model-paths-config /workspace/extra_model_paths.yaml

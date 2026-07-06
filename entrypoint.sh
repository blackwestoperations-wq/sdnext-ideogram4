#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/workspace"
REMOTE="dospaces"
RCLONE_FLAGS="--inplace --s3-no-check-bucket --transfers 6 --checkers 8 --retries 3 --low-level-retries 5"

echo "=========================================="
echo "ComfyUI + DO Spaces (Stateless Boot)"
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
# Workspace dirs
# ---------------------------------------------------

mkdir -p \
    ${WORKSPACE}/models \
    ${WORKSPACE}/custom_nodes \
    ${WORKSPACE}/user \
    ${WORKSPACE}/input \
    ${WORKSPACE}/output \
    ${WORKSPACE}/workflows

# ---------------------------------------------------
# Download models from Spaces (with --inplace to fix rename errors)
# ---------------------------------------------------

echo "BOOT: Mounting models from Spaces..."

mkdir -p ${WORKSPACE}/models

# Mount with VFS full cache (downloads on access, caches locally)
rclone mount \
    ${REMOTE}:${SPACES_BUCKET}/models \
    ${WORKSPACE}/models \
    --vfs-cache-mode full \
    --vfs-cache-max-size 40G \
    --vfs-cache-max-age 168h \
    --dir-cache-time 1m \
    --attr-timeout 30s \
    --buffer-size 512M \
    --daemon \
    --allow-other \
    --s3-no-check-bucket \
    --umask 022 \
    || echo "FATAL: rclone mount failed, falling back to copy"

# Check if mount succeeded
sleep 2
if mountpoint -q ${WORKSPACE}/models; then
    echo "Models mounted successfully (lazy loading enabled)"
else
    echo "Mount failed, falling back to rclone copy..."
    rclone copy \
        ${REMOTE}:${SPACES_BUCKET}/models \
        ${WORKSPACE}/models \
        ${RCLONE_FLAGS} \
        --ignore-existing \
        --exclude "*.partial" \
        || true
fi

# ---------------------------------------------------
# Download workflows
# ---------------------------------------------------

echo "BOOT: Downloading workflows..."

rclone copy \
    ${REMOTE}:${SPACES_BUCKET}/workflows \
    ${WORKSPACE}/workflows \
    ${RCLONE_FLAGS} \
    --ignore-existing \
    --exclude "*.partial" \
    || echo "WARN: workflow sync had issues, continuing..."

# ---------------------------------------------------
# Download user settings & Manager config
# ---------------------------------------------------

echo "BOOT: Downloading user data..."

rclone copy \
    ${REMOTE}:${SPACES_BUCKET}/user \
    ${WORKSPACE}/user \
    ${RCLONE_FLAGS} \
    --ignore-existing \
    --exclude "*.partial" \
    || echo "WARN: user data sync had issues, continuing..."

# ---------------------------------------------------
# Download custom_nodes (persist installed nodes)
# ---------------------------------------------------

echo "BOOT: Downloading custom_nodes..."

rclone copy \
    ${REMOTE}:${SPACES_BUCKET}/custom_nodes \
    ${WORKSPACE}/custom_nodes \
    ${RCLONE_FLAGS} \
    --ignore-existing \
    --exclude "*.partial" \
    --exclude "__pycache__/**" \
    --exclude "*.pyc" \
    || echo "WARN: custom_nodes sync had issues, continuing..."

# Install any requirements from synced custom_nodes
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
# Link workspace into ComfyUI
# ---------------------------------------------------

for dir in models input output user; do
    rm -rf /app/${dir}
    ln -s ${WORKSPACE}/${dir} /app/${dir}
done

# Merge custom_nodes: symlink synced ones into /app/custom_nodes
mkdir -p /app/custom_nodes
if [ -d "${WORKSPACE}/custom_nodes" ]; then
    for node_dir in ${WORKSPACE}/custom_nodes/*/; do
        node_name=$(basename "$node_dir")
        if [ "$node_name" != "*" ] && [ ! -L "/app/custom_nodes/${node_name}" ]; then
            ln -s "${node_dir}" "/app/custom_nodes/${node_name}"
        fi
    done
fi

# Ensure ComfyUI-Manager exists (it's in the Docker image already)
if [ ! -d "/app/custom_nodes/ComfyUI-Manager" ]; then
    ln -s /app/custom_nodes/ComfyUI-Manager /app/custom_nodes/ComfyUI-Manager 2>/dev/null || true
fi

mkdir -p /app/user/__manager

# ---------------------------------------------------
# ComfyUI Manager configuration
# ---------------------------------------------------

CONFIG_CONTENT='[default]
security_level = weak
allow_git_url_install = true
network_mode = public
update_policy = stable
skip_migration_check = true
'

for DIR in \
    /app/user/__manager \
    /app/user/default/ComfyUI-Manager \
    /app/user/ComfyUI-Manager
do
    mkdir -p "$DIR"
    echo "$CONFIG_CONTENT" > "$DIR/config.ini"
done

echo "ComfyUI Manager configured."

# ---------------------------------------------------
# Background sync: Upload outputs + new models + custom_nodes to Spaces
# ---------------------------------------------------

sync_to_spaces() {
    while true; do
        sleep 120

        echo "[SYNC] Uploading outputs..."
        rclone copy \
            ${WORKSPACE}/output \
            ${REMOTE}:${SPACES_BUCKET}/output \
            ${RCLONE_FLAGS} \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            --log-level ERROR \
            || true

        echo "[SYNC] Uploading new models..."
        rclone copy \
            ${WORKSPACE}/models \
            ${REMOTE}:${SPACES_BUCKET}/models \
            ${RCLONE_FLAGS} \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            --log-level ERROR \
            || true

        echo "[SYNC] Uploading custom_nodes..."
        rclone copy \
            /app/custom_nodes \
            ${REMOTE}:${SPACES_BUCKET}/custom_nodes \
            ${RCLONE_FLAGS} \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "__pycache__/**" \
            --exclude "*.pyc" \
            --exclude "*/.git/**" \
            --log-level ERROR \
            || true

        echo "[SYNC] Upload complete."
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

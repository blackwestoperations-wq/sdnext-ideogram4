#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/workspace"
REMOTE="dospaces"
# FIXED: removed --inplace (skips atomic write protection, risks corrupt models on interrupted transfers)
RCLONE_FLAGS="--s3-no-check-bucket --transfers 6 --checkers 8 --retries 3 --low-level-retries 5"

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
# Pre-create model subdirs so ComfyUI sees them even before sync completes
# ---------------------------------------------------
mkdir -p \
    "${WORKSPACE}/models/checkpoints" \
    "${WORKSPACE}/models/vae" \
    "${WORKSPACE}/models/loras" \
    "${WORKSPACE}/models/embeddings" \
    "${WORKSPACE}/models/controlnet" \
    "${WORKSPACE}/models/clip" \
    "${WORKSPACE}/models/unet" \
    "${WORKSPACE}/models/upscale_models" \
    "${WORKSPACE}/models/gligen" \
    "${WORKSPACE}/custom_nodes" \
    "${WORKSPACE}/user" \
    "${WORKSPACE}/input" \
    "${WORKSPACE}/output" \
    "${WORKSPACE}/workflows"

# ---------------------------------------------------
# Link workspace into ComfyUI app directory
# Must happen before ComfyUI starts
# ---------------------------------------------------
for dir in models input output user; do
    rm -rf /app/${dir}
    ln -s "${WORKSPACE}/${dir}" "/app/${dir}"
done

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
# Attempt FUSE lazy mount for models
# FIXED: errors now logged to file instead of /dev/null
# ---------------------------------------------------
echo "BOOT: Checking for FUSE device..."
MODELS_MOUNTED=false

if [ -e /dev/fuse ]; then
    echo "BOOT: /dev/fuse found. Attempting to mount models from Spaces..."
    modprobe fuse 2>/dev/null || true

    rclone mount \
        "${REMOTE}:${SPACES_BUCKET}/models" \
        "${WORKSPACE}/models" \
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
        2>/tmp/rclone-mount.log || true

    sleep 3
    if mountpoint -q "${WORKSPACE}/models"; then
        echo "✅ Models mounted successfully (lazy loading enabled)."
        MODELS_MOUNTED=true
    else
        echo "⚠️ Mount failed. Reason:"
        cat /tmp/rclone-mount.log
        echo "Will copy models in background after ComfyUI starts."
    fi
else
    echo "⚠️ /dev/fuse not found. Models will be copied in background."
fi

# ---------------------------------------------------
# Quick-sync small directories BEFORE ComfyUI starts
# These are needed at startup time. Models are large — handled below.
# ---------------------------------------------------
echo "BOOT: Quick-syncing custom_nodes (90s max)..."
timeout 90 rclone copy \
    "${REMOTE}:${SPACES_BUCKET}/custom_nodes" "${WORKSPACE}/custom_nodes" \
    ${RCLONE_FLAGS} --ignore-existing \
    --exclude "*.partial" --exclude "__pycache__/**" --exclude "*.pyc" \
    2>&1 || echo "WARN: custom_nodes sync incomplete — continuing with whatever arrived"

echo "BOOT: Quick-syncing user data (30s max)..."
timeout 30 rclone copy \
    "${REMOTE}:${SPACES_BUCKET}/user" "${WORKSPACE}/user" \
    ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" \
    2>&1 || echo "WARN: user sync incomplete — continuing"

echo "BOOT: Quick-syncing workflows (30s max)..."
timeout 30 rclone copy \
    "${REMOTE}:${SPACES_BUCKET}/workflows" "${WORKSPACE}/workflows" \
    ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" \
    2>&1 || echo "WARN: workflows sync incomplete — continuing"

# Install requirements for any synced custom nodes
mkdir -p /app/custom_nodes
if [ -d "${WORKSPACE}/custom_nodes" ]; then
    for req in "${WORKSPACE}"/custom_nodes/*/requirements.txt; do
        [ -f "$req" ] || continue
        node_name=$(basename "$(dirname "$req")")
        echo "  Installing deps for: ${node_name}"
        pip install -r "$req" --quiet || echo "  WARN: failed deps for ${node_name}"
    done

    # Link synced custom nodes into /app/custom_nodes
    for node_dir in "${WORKSPACE}"/custom_nodes/*/; do
        node_name=$(basename "$node_dir")
        [ "$node_name" = "*" ] && continue
        [ -e "/app/custom_nodes/${node_name}" ] && continue
        ln -s "${node_dir}" "/app/custom_nodes/${node_name}"
    done
fi

# ---------------------------------------------------
# FIXED: Background model copy — does NOT block ComfyUI startup
# Models are large (GBs); copying them before starting caused the health
# check crash loop. ComfyUI starts with empty dirs and picks up models
# as they arrive. Users will see models appear without restarting.
# ---------------------------------------------------
if [ "$MODELS_MOUNTED" = "false" ]; then
    echo "BOOT: Launching background model copy from Spaces..."
    (
        rclone copy \
            "${REMOTE}:${SPACES_BUCKET}/models" \
            "${WORKSPACE}/models" \
            ${RCLONE_FLAGS} \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            --log-level INFO \
            2>&1 | tee /tmp/rclone-models.log
        echo "BOOT: Background model copy complete."
    ) &
fi

# ---------------------------------------------------
# Background sync loop: push outputs and changes back to Spaces
# ---------------------------------------------------
sync_to_spaces() {
    while true; do
        sleep 120

        rclone copy "${WORKSPACE}/output" "${REMOTE}:${SPACES_BUCKET}/output" \
            ${RCLONE_FLAGS} --ignore-existing \
            --exclude "*.partial" --exclude "*.tmp" --log-level ERROR || true

        rclone copy /app/custom_nodes "${REMOTE}:${SPACES_BUCKET}/custom_nodes" \
            ${RCLONE_FLAGS} --ignore-existing \
            --exclude "*.partial" --exclude "__pycache__/**" \
            --exclude "*.pyc" --exclude "*/.git/**" --log-level ERROR || true

        rclone copy "${WORKSPACE}/user" "${REMOTE}:${SPACES_BUCKET}/user" \
            ${RCLONE_FLAGS} --ignore-existing --exclude "*.partial" --log-level ERROR || true

        # Only sync models back if not FUSE-mounted (mount writes through transparently)
        if ! mountpoint -q "${WORKSPACE}/models" 2>/dev/null; then
            rclone copy "${WORKSPACE}/models" "${REMOTE}:${SPACES_BUCKET}/models" \
                ${RCLONE_FLAGS} --ignore-existing \
                --exclude "*.partial" --exclude "*.tmp" --log-level ERROR || true
        fi
    done
}
sync_to_spaces &

# ---------------------------------------------------
# Start ComfyUI
#
# FIXED: --extra-model-paths-config removed.
#   extra_model_paths.yaml pointed to /mnt/spaces which is never created
#   or mounted anywhere in this setup. Models are available at
#   /app/models (symlinked from /workspace/models) which is ComfyUI's
#   default path — no extra config needed.
#
# exec replaces the shell so Docker signals (SIGTERM on stop) go
# directly to ComfyUI rather than being absorbed by bash.
# ---------------------------------------------------
echo "=========================================="
echo "Starting ComfyUI..."
echo "=========================================="
exec python /app/main.py \
    --listen 0.0.0.0 \
    --port 8188

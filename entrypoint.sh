#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# ComfyUI + DigitalOcean Spaces — rclone mount edition
# =====================================================
# Strategy:
#   1. Try rclone mount (instant boot, on-demand model fetching)
#   2. Fallback: start ComfyUI immediately + background download
#   3. Custom nodes synced at boot (small, needed for imports)
#   4. Outputs uploaded in background
# =====================================================

WORKSPACE="/workspace"
REMOTE="dospaces"
MAX_RETRIES=3

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=========================================="
log "ComfyUI + DO Spaces (rclone mount)"
log "=========================================="

# ---------------------------------------------------
# GPU diagnostics
# ---------------------------------------------------

python - <<'EOF'
import torch
print(f"PyTorch:  {torch.__version__}")
print(f"CUDA:     {torch.cuda.is_available()}")
if torch.cuda.is_available():
    props = torch.cuda.get_device_properties(0)
    print(f"GPU:      {props.name}")
    print(f"VRAM:     {props.total_memory / 1024**3:.1f} GB")
EOF

# ---------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------

REQUIRED_VARS=(
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION
    SPACES_BUCKET
)

MISSING=0
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "ERROR: Required env var ${var} is not set"
        MISSING=1
    fi
done
[[ $MISSING -eq 1 ]] && exit 1

SPACES_ENDPOINT="${SPACES_ENDPOINT:-ams3.digitaloceanspaces.com}"
log "Endpoint: ${SPACES_ENDPOINT}"
log "Bucket:   ${SPACES_BUCKET}"

# ---------------------------------------------------
# Configure rclone
# ---------------------------------------------------

mkdir -p /root/.config/rclone

cat > /root/.config/rclone/rclone.conf <<EOF
[${REMOTE}]
type = s3
provider = DigitalOcean
env_auth = false
access_key_id = ${AWS_ACCESS_KEY_ID}
secret_access_key = ${AWS_SECRET_ACCESS_KEY}
endpoint = ${SPACES_ENDPOINT}
region = ${AWS_DEFAULT_REGION}
acl = private
EOF

log "rclone configured."

# ---------------------------------------------------
# Create workspace directories
# ---------------------------------------------------

mkdir -p \
    "${WORKSPACE}/models" \
    "${WORKSPACE}/custom_nodes" \
    "${WORKSPACE}/user" \
    "${WORKSPACE}/input" \
    "${WORKSPACE}/output" \
    "${WORKSPACE}/workflows" \
    /tmp/rclone-cache

# ---------------------------------------------------
# Sync helper with retry
# ---------------------------------------------------

sync_from_remote() {
    local remote_subpath="$1"
    local local_path="$2"
    local label="$3"
    local extra_excludes="${4:-}"

    local attempt=1
    while [[ ${attempt} -le ${MAX_RETRIES} ]]; do
        log "[${label}] Sync attempt ${attempt}/${MAX_RETRIES}..."

        if rclone copy \
            "${REMOTE}:${SPACES_BUCKET}/${remote_subpath}" \
            "${local_path}" \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            --transfers 6 \
            --checkers 8 \
            --retries 3 \
            --low-level-retries 10 \
            --s3-no-check-bucket \
            --stats 2m \
            --stats-one-line \
            --log-level INFO \
            ${extra_excludes}; then
            log "[${label}] Sync complete."
            return 0
        fi

        local wait_sec=$(( attempt * 10 ))
        log "[${label}] Failed (attempt ${attempt}/${MAX_RETRIES}). Retrying in ${wait_sec}s..."
        sleep ${wait_sec}
        attempt=$(( attempt + 1 ))
    done

    log "[${label}] WARNING: All ${MAX_RETRIES} attempts failed."
    return 1
}

# ---------------------------------------------------
# Sync small directories first (needed at boot)
# ---------------------------------------------------

log "=== Phase 1: Syncing custom nodes ==="
sync_from_remote "custom_nodes" "${WORKSPACE}/custom_nodes" "CUSTOM_NODES" "--exclude ComfyUI-Manager/**"

log "=== Phase 2: Syncing workflows ==="
sync_from_remote "workflows" "${WORKSPACE}/workflows" "WORKFLOWS"

# ---------------------------------------------------
# Model loading strategy: try rclone mount, fallback to copy
# ---------------------------------------------------

USE_MOUNT=false

if [[ -e /dev/fuse ]] || [[ -c /dev/fuse ]]; then
    log "=== Phase 3: Attempting rclone mount ==="
    log "FUSE device found at /dev/fuse"

    # Clear models directory for mount
    rm -rf "${WORKSPACE}/models"
    mkdir -p "${WORKSPACE}/models"

    # Start rclone mount in background
    rclone mount \
        "${REMOTE}:${SPACES_BUCKET}/models" \
        "${WORKSPACE}/models" \
        --vfs-cache-mode full \
        --cache-dir /tmp/rclone-cache \
        --dir-cache-time 1h \
        --attr-timeout 1h \
        --vfs-read-chunk-size 64M \
        --vfs-read-chunk-size-limit 512M \
        --transfers 4 \
        --checkers 8 \
        --s3-no-check-bucket \
        --log-level INFO \
        --log-file /tmp/rclone-mount.log &

    RCLONE_MOUNT_PID=$!

    # Wait for mount to become available
    MOUNT_READY=false
    for i in $(seq 1 15); do
        sleep 1
        if mountpoint -q "${WORKSPACE}/models" 2>/dev/null; then
            MOUNT_READY=true
            break
        fi
        # Alternative check if mountpoint command isn't available
        if [[ -n "$(ls -A ${WORKSPACE}/models 2>/dev/null)" ]]; then
            MOUNT_READY=true
            break
        fi
    done

    if [[ "${MOUNT_READY}" == "true" ]]; then
        log "rclone mount successful! Models are available on-demand."
        log "Models will be fetched from Spaces as they're loaded."
        USE_MOUNT=true

        # List available models (triggers S3 LIST — fast)
        log "=== Available models (remote listing) ==="
        rclone lsf \
            "${REMOTE}:${SPACES_BUCKET}/models" \
            --recursive \
            --s3-no-check-bucket \
            --files-only \
            2>/dev/null | head -50 || true
        log "(showing first 50 — more may exist)"
    else
        log "rclone mount failed — /dev/fuse exists but mount didn't come up."
        log "Check /tmp/rclone-mount.log for details."
        log "Falling back to background sync mode."
        kill ${RCLONE_MOUNT_PID} 2>/dev/null || true
        sleep 2
        rm -rf "${WORKSPACE}/models"
        mkdir -p "${WORKSPACE}/models"
    fi
else
    log "=== Phase 3: /dev/fuse not found — using background sync ==="
    mkdir -p "${WORKSPACE}/models"
fi

# ---------------------------------------------------
# Fallback: background model download
# ---------------------------------------------------

if [[ "${USE_MOUNT}" == "false" ]]; then
    log "Starting background model download..."
    log "ComfyUI will boot immediately — models appear as they download."

    (
        log "[MODEL-SYNC] Downloading from Spaces..."

        # Download checkpoints first (most commonly needed)
        rclone copy \
            "${REMOTE}:${SPACES_BUCKET}/models/checkpoints" \
            "${WORKSPACE}/models/checkpoints" \
            --ignore-existing \
            --exclude "*.partial" \
            --transfers 4 \
            --checkers 8 \
            --s3-no-check-bucket \
            --log-level ERROR \
            || true

        log "[MODEL-SYNC] Checkpoints done. Downloading remaining models..."

        # Then everything else
        rclone copy \
            "${REMOTE}:${SPACES_BUCKET}/models" \
            "${WORKSPACE}/models" \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "checkpoints/**" \
            --transfers 4 \
            --checkers 8 \
            --s3-no-check-bucket \
            --log-level ERROR \
            || true

        log "[MODEL-SYNC] All models downloaded."
    ) &

    # Also run periodic sync to catch newly uploaded models
    (
        sleep 300
        while true; do
            log "[MODEL-SYNC] Checking for new models..."
            rclone copy \
                "${REMOTE}:${SPACES_BUCKET}/models" \
                "${WORKSPACE}/models" \
                --ignore-existing \
                --exclude "*.partial" \
                --transfers 2 \
                --checkers 4 \
                --s3-no-check-bucket \
                --log-level ERROR \
                || true
            sleep 600
        done
    ) &
fi

# ---------------------------------------------------
# Link workspace into ComfyUI
# ---------------------------------------------------

for dir in models input output user; do
    rm -rf "/app/${dir}"
    ln -s "${WORKSPACE}/${dir}" "/app/${dir}"
done

# Copy synced custom nodes into ComfyUI's custom_nodes directory
# (ComfyUI-Manager is already in /app/custom_nodes/ from Docker build)
if [[ -d "${WORKSPACE}/custom_nodes" ]] && [[ -n "$(ls -A ${WORKSPACE}/custom_nodes 2>/dev/null)" ]]; then
    log "Copying synced custom nodes into ComfyUI..."
    cp -rn "${WORKSPACE}/custom_nodes/"* /app/custom_nodes/ 2>/dev/null || true

    # Install requirements for synced custom nodes
    log "Checking custom node requirements..."
    find /app/custom_nodes -name "requirements.txt" -maxdepth 2 | while read req; do
        log "  Installing: ${req}"
        pip install -r "${req}" --quiet 2>/dev/null || true
    done
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
    mkdir -p "${DIR}"
    echo "${CONFIG_CONTENT}" > "${DIR}/config.ini"
done

log "ComfyUI Manager configured."

# ---------------------------------------------------
# Background: Output uploader
# ---------------------------------------------------

(
    while true; do
        sleep 30

        if [[ -z "$(ls -A ${WORKSPACE}/output 2>/dev/null)" ]]; then
            continue
        fi

        log "[OUTPUT] Uploading..."
        rclone copy \
            "${WORKSPACE}/output" \
            "${REMOTE}:${SPACES_BUCKET}/output" \
            --ignore-existing \
            --exclude "*.partial" \
            --exclude "*.tmp" \
            --transfers 4 \
            --checkers 4 \
            --s3-no-check-bucket \
            --log-level ERROR \
            || log "[OUTPUT] Upload failed — will retry."
    done
) &

# ---------------------------------------------------
# Background: Custom nodes uploader
# (Persists nodes installed via web UI)
# ---------------------------------------------------

(
    sleep 120
    while true; do
        if [[ -n "$(ls -A /app/custom_nodes 2>/dev/null)" ]]; then
            rclone copy \
                /app/custom_nodes \
                "${REMOTE}:${SPACES_BUCKET}/custom_nodes" \
                --ignore-existing \
                --exclude "ComfyUI-Manager/**" \
                --exclude "__pycache__/**" \
                --exclude "*.pyc" \
                --transfers 2 \
                --checkers 4 \
                --s3-no-check-bucket \
                --log-level ERROR \
                || true
        fi
        sleep 300
    done
) &

# ---------------------------------------------------
# If using mount, keep rclone alive
# ---------------------------------------------------

if [[ "${USE_MOUNT}" == "true" ]]; then
    (
        while true; do
            if ! kill -0 ${RCLONE_MOUNT_PID} 2>/dev/null; then
                log "[MOUNT] rclone mount process died! Attempting restart..."
                rclone mount \
                    "${REMOTE}:${SPACES_BUCKET}/models" \
                    "${WORKSPACE}/models" \
                    --vfs-cache-mode full \
                    --cache-dir /tmp/rclone-cache \
                    --dir-cache-time 1h \
                    --attr-timeout 1h \
                    --vfs-read-chunk-size 64M \
                    --vfs-read-chunk-size-limit 512M \
                    --transfers 4 \
                    --checkers 8 \
                    --s3-no-check-bucket \
                    --log-level INFO \
                    --log-file /tmp/rclone-mount.log &
                RCLONE_MOUNT_PID=$!
            fi
            sleep 30
        done
    ) &
fi

# ---------------------------------------------------
# Start ComfyUI
# ---------------------------------------------------

log "=========================================="
log "Starting ComfyUI on 0.0.0.0:8188"
if [[ "${USE_MOUNT}" == "true" ]]; then
    log "Mode: rclone mount (on-demand fetching)"
else
    log "Mode: background sync (models downloading)"
fi
log "=========================================="

exec python /app/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --extra-model-paths-config /workspace/extra_model_paths.yaml

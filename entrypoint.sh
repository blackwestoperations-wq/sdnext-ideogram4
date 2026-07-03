#!/bin/bash
set -e

echo "========================================"
echo "  ComfyUI + Manager  |  Koyeb Startup"
echo "========================================"

export HF_HUB_ENABLE_HF_TRANSFER=1

# ── Model downloader ──────────────────────────────────────────────────────────
download_model() {
  local URL="$1"
  local DEST="$2"

  if [ -f "$DEST" ]; then
    echo "[SKIP] Already present: $(basename "$DEST")"
    return 0
  fi

  mkdir -p "$(dirname "$DEST")"
  echo "[DOWN] $(basename "$DEST") → $DEST"

  if [ -n "$HF_TOKEN" ]; then
    wget -q --show-progress \
         --header="Authorization: Bearer ${HF_TOKEN}" \
         -O "${DEST}.tmp" "$URL" && mv "${DEST}.tmp" "$DEST"
  else
    wget -q --show-progress \
         -O "${DEST}.tmp" "$URL" && mv "${DEST}.tmp" "$DEST"
  fi

  echo "[DONE] $(basename "$DEST")"
}

# ── Download models in the background ────────────────────────────────────────
# This lets ComfyUI start immediately so Koyeb health checks pass.
# ComfyUI will wait for model files when a workflow is first run.
(
  echo ""
  echo "--- Background model downloads starting ---"
  while IFS=' ' read -r URL DEST || [ -n "$URL" ]; do
    [[ -z "$URL" || "$URL" == \#* ]] && continue
    download_model "$URL" "$DEST"
  done < /app/models.txt
  echo "--- All models downloaded ---"
) &

# ── Launch ComfyUI immediately ────────────────────────────────────────────────
# Starts right away so Koyeb health checks pass while models download in background.
echo ""
echo "Starting ComfyUI on port 8188..."
exec python3 /app/main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --enable-cors-header "*"

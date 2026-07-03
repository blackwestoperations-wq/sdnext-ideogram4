bash

cat > /home/claude/comfyui-koyeb/entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "========================================"
echo "  ComfyUI + Manager  |  Koyeb Startup"
echo "========================================"

# Use explicit python path — avoids picking up wrong system Python
PYTHON=$(which python3)
echo "Python: $PYTHON ($($PYTHON --version))"

# Quick CUDA check — won't crash if GPU not visible yet, just informs
$PYTHON -c "
import torch
print('PyTorch:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('GPU:', torch.cuda.get_device_name(0))
    print('VRAM:', round(torch.cuda.get_device_properties(0).total_memory / 1024**3, 1), 'GB')
else:
    print('WARNING: CUDA not available — ComfyUI will run on CPU (very slow)')
" || echo "WARNING: torch check failed"

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
(
  echo "--- Background model downloads starting ---"
  while IFS=' ' read -r URL DEST || [ -n "$URL" ]; do
    [[ -z "$URL" || "$URL" == \#* ]] && continue
    download_model "$URL" "$DEST"
  done < /app/models.txt
  echo "--- All models downloaded ---"
) &

# ── Launch ComfyUI immediately so health checks pass ─────────────────────────
echo "Starting ComfyUI on port 8188..."
exec $PYTHON /app/main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --enable-cors-header "*"

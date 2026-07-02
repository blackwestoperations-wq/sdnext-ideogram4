#!/bin/bash
set -e

echo "==> Starting ComfyUI setup..."

# Speed up HuggingFace downloads
export HF_HUB_ENABLE_HF_TRANSFER=1

# Download models listed in models.txt
# Format: URL DESTINATION_PATH
while IFS= read -r line || [ -n "$line" ]; do
  # Skip blank lines and comments
  [[ -z "$line" || "$line" == \#* ]] && continue

  URL=$(echo "$line" | awk '{print $1}')
  DEST=$(echo "$line" | awk '{print $2}')

  if [ ! -f "$DEST" ]; then
    echo "==> Downloading: $URL"
    echo "    → $DEST"
    mkdir -p "$(dirname "$DEST")"
    aria2c --console-log-level=error \
           --summary-interval=0 \
           -x 8 -s 8 -k 1M \
           --out="$DEST" "$URL" \
           --header="Authorization: Bearer ${HF_TOKEN}" || \
    wget -q --show-progress \
         --header="Authorization: Bearer ${HF_TOKEN}" \
         -O "$DEST" "$URL"
    echo "    ✓ Done"
  else
    echo "==> Already exists, skipping: $DEST"
  fi
done < /app/models.txt

echo "==> All models ready. Starting ComfyUI..."

exec python3 /app/main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --enable-cors-header "*"

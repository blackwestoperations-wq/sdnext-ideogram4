#!/bin/bash
set -e

echo "========================================"
echo "  ComfyUI + Manager | Koyeb Startup"
echo "========================================"

PYTHON=$(which python3)
echo "Python: $PYTHON ($($PYTHON --version))"

# Display GPU information
$PYTHON - <<'EOF'
import torch

print("PyTorch:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
    print("VRAM:", round(torch.cuda.get_device_properties(0).total_memory / 1024**3, 1), "GB")
else:
    print("WARNING: CUDA not available — ComfyUI will run on CPU.")
EOF

echo "Starting ComfyUI on port 8188..."

exec $PYTHON /app/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --enable-cors-header "*"

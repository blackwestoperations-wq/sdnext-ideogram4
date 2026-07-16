#!/usr/bin/env bash

set -e

PORT="${PORT:-8188}"

echo
echo "========================================="
echo "ComfyUI starting..."
echo "========================================="

echo
echo "Python:"
python3 --version

echo
echo "Torch:"
python3 - <<EOF
import torch
print(torch.__version__)
print("CUDA:", torch.version.cuda)
print("CUDA Available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
EOF

echo
echo "Compiler:"
which gcc
gcc --version

echo
echo "Working directory:"
pwd

echo
echo "Launching ComfyUI..."

cd /app/ComfyUI

exec python3 main.py \
    --listen 0.0.0.0 \
    --port "${PORT}" \
    --disable-auto-launch

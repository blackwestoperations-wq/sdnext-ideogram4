#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# ComfyUI Startup Script for Koyeb GPU
# ==========================================================

PORT="${PORT:-8188}"

echo
echo "========================================="
echo "ComfyUI starting..."
echo "========================================="

# ----------------------------------------------------------
# Create required directories
# ----------------------------------------------------------

mkdir -p \
    /app/ComfyUI/user \
    /app/ComfyUI/user/default \
    /app/ComfyUI/user/__manager \
    /app/ComfyUI/input \
    /app/ComfyUI/output \
    /app/ComfyUI/temp

# ----------------------------------------------------------
# ComfyUI Manager Configuration
# ----------------------------------------------------------

cat >/app/ComfyUI/user/__manager/config.ini <<'CONFIG_EOF'
[default]

# Security
security_level = weak

# Cloud deployment
network_mode = personal_cloud

# Allow installs
allow_git_url_install = true
allow_pip_install = true

# Git
git_exe = git
use_uv = false

# Logging
file_logging = true

# Startup
always_lazy_install = false

# Downloads
model_download_by_agent = true

# Misc
default_cache_as_channel_url = false
bypass_ssl = false
downgrade_blacklist =
CONFIG_EOF

echo
echo "========== Manager Config =========="
cat /app/ComfyUI/user/__manager/config.ini
echo "===================================="

# ----------------------------------------------------------
# Environment
# ----------------------------------------------------------

export CC=/usr/bin/gcc
export CXX=/usr/bin/g++
export CUDA_HOME=/usr/local/cuda
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}

# Allow Manager Git installs
export ALLOW_GIT_URL_INSTALL=1

# ----------------------------------------------------------
# Diagnostics
# ----------------------------------------------------------

echo
echo "Python:"
python3 --version

echo
echo "Git:"
git --version

echo
echo "Compiler:"
which gcc
gcc --version

echo
echo "Torch:"
python3 <<'PYTHON_INFO'
import torch

print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
    print("GPU Count:", torch.cuda.device_count())
PYTHON_INFO

echo
echo "Working directory:"
pwd

echo
echo "Manager config location:"
ls -la /app/ComfyUI/user/__manager

echo
echo "Launching ComfyUI..."

cd /app/ComfyUI

exec python3 main.py \
    --listen 0.0.0.0 \
    --port "${PORT}" \
    --disable-auto-launch

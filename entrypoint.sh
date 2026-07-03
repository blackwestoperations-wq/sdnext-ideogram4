#!/usr/bin/env bash
set -e

WORKSPACE=/workspace
REMOTE=dospaces

echo "=========================================="
echo "ComfyUI + DigitalOcean Spaces"
echo "=========================================="

python - <<EOF
import torch
print("PyTorch:", torch.__version__)
print("CUDA:", torch.cuda.is_available())
if torch.cuda.is_available():
    print(torch.cuda.get_device_name(0))
EOF

mkdir -p /root/.config/rclone

cat >/root/.config/rclone/rclone.conf <<EOF
[$REMOTE]
type = s3
provider = DigitalOcean
env_auth = false
access_key_id = ${AWS_ACCESS_KEY_ID}
secret_access_key = ${AWS_SECRET_ACCESS_KEY}
endpoint = ${SPACES_ENDPOINT}
region = ${AWS_DEFAULT_REGION}
acl = private
EOF

echo "Downloading workspace..."

mkdir -p ${WORKSPACE}

if rclone lsd ${REMOTE}:${SPACES_BUCKET}; then

    rclone copy \
        ${REMOTE}:${SPACES_BUCKET} \
        ${WORKSPACE} \
        --fast-list \
        --transfers 16 \
        --checkers 16

fi

mkdir -p \
${WORKSPACE}/models \
${WORKSPACE}/custom_nodes \
${WORKSPACE}/user \
${WORKSPACE}/input \
${WORKSPACE}/output \
${WORKSPACE}/workflows

rm -rf /app/models
ln -s ${WORKSPACE}/models /app/models

rm -rf /app/custom_nodes
ln -s ${WORKSPACE}/custom_nodes /app/custom_nodes

rm -rf /app/user
ln -s ${WORKSPACE}/user /app/user

rm -rf /app/output
ln -s ${WORKSPACE}/output /app/output

rm -rf /app/input
ln -s ${WORKSPACE}/input /app/input

if [ ! -d /app/custom_nodes/ComfyUI-Manager ]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git \
    /app/custom_nodes/ComfyUI-Manager

    pip install \
    -r /app/custom_nodes/ComfyUI-Manager/requirements.txt
fi

(
while true
do
sleep 60

echo "Uploading changes..."

rclone copy \
${WORKSPACE} \
${REMOTE}:${SPACES_BUCKET} \
--fast-list \
--transfers 16 \
--checkers 16

done
) &

echo "Starting ComfyUI..."

exec python /app/main.py \
--listen 0.0.0.0 \
--port 8188 \
--extra-model-paths-config /workspace/extra_model_paths.yaml

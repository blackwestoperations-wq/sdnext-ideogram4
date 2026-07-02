FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y \
    git python3.11 python3.11-venv python3-pip \
    libgl1 libglib2.0-0 wget \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.11 /usr/bin/python3

WORKDIR /app

RUN git clone https://github.com/vladmandic/sdnext.git .

RUN python3 -m venv venv
ENV PATH="/app/venv/bin:$PATH"

RUN python3 launch.py --skip-git --debug --test || true

RUN pip install -U huggingface_hub

ARG HF_TOKEN
# --cache-dir (not --local-dir) preserves the models--<author>--<repo> layout
# SD.Next expects under <models-dir>/Diffusers
RUN hf auth login --token "$HF_TOKEN" && \
    hf download ideogram-ai/ideogram-4-fp8 \
    --cache-dir /app/models/Diffusers

EXPOSE 7860

# Removed --ckpt-dir: not a valid SD.Next argument
CMD ["python3", "launch.py", "--listen", "--port", "7860", "--use-cuda", "--api", \
     "--models-dir", "/app/models"]

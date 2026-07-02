FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

# System deps
RUN apt-get update && apt-get install -y \
    git python3.11 python3.11-venv python3-pip \
    libgl1 libglib2.0-0 wget \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.11 /usr/bin/python3

WORKDIR /app

# Clone SD.Next
RUN git clone https://github.com/vladmandic/sdnext.git .

# Pre-create venv and install deps (first run does this too, but baking it in speeds cold starts)
RUN python3 -m venv venv
ENV PATH="/app/venv/bin:$PATH"

# Koyeb routes to the port your app listens on
EXPOSE 7860

# --listen so it's reachable outside localhost, --use-cuda to force the CUDA backend
CMD ["python3", "launch.py", "--listen", "--port", "7860", "--use-cuda", "--api"]

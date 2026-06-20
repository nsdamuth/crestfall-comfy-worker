FROM runpod/worker-comfyui:5.8.6-base

USER root

ARG COMFYUI_COMMIT=a4fa18e8999bdae888f8e88cd872fae48298ece6

RUN command -v git >/dev/null 2>&1 || \
    (apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*)

# Force a known-good ComfyUI source tree.
# Do not trust whatever partial /ComfyUI may exist in the base image.
RUN rm -rf /ComfyUI && \
    git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI && \
    cd /ComfyUI && \
    git checkout ${COMFYUI_COMMIT} && \
    test -f /ComfyUI/main.py && \
    test -f /ComfyUI/comfy/sd.py && \
    test -f /ComfyUI/comfy/ldm/models/autoencoder.py

# The base image already has most of the heavy CUDA/Torch stack.
# Install Comfy's Python requirements without replacing the whole environment manually.
RUN python3 -m pip install --no-cache-dir -r /ComfyUI/requirements.txt

# Required custom nodes for our exported workflows.
RUN mkdir -p /ComfyUI/custom_nodes && \
    git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git /ComfyUI/custom_nodes/comfyui_ipadapter_plus && \
    if [ -f "/ComfyUI/custom_nodes/comfyui_ipadapter_plus/requirements.txt" ]; then \
      python3 -m pip install --no-cache-dir -r /ComfyUI/custom_nodes/comfyui_ipadapter_plus/requirements.txt; \
    fi

RUN mkdir -p /ComfyUI/custom_nodes && \
    git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git /ComfyUI/custom_nodes/ComfyUI-KJNodes && \
    if [ -f "/ComfyUI/custom_nodes/ComfyUI-KJNodes/requirements.txt" ]; then \
      python3 -m pip install --no-cache-dir -r /ComfyUI/custom_nodes/ComfyUI-KJNodes/requirements.txt; \
    fi

WORKDIR /workspace/crestfall-comfy-worker

COPY requirements.txt /workspace/crestfall-comfy-worker/requirements.txt
RUN python3 -m pip install --no-cache-dir -r /workspace/crestfall-comfy-worker/requirements.txt

COPY handler.py /workspace/crestfall-comfy-worker/handler.py
COPY local_comfy_worker.py /workspace/crestfall-comfy-worker/local_comfy_worker.py
COPY workflow_registry.py /workspace/crestfall-comfy-worker/workflow_registry.py
COPY model_sync.py /workspace/crestfall-comfy-worker/model_sync.py
COPY start.sh /workspace/crestfall-comfy-worker/start.sh
COPY rp_handler.py /workspace/crestfall-comfy-worker/rp_handler.py

COPY workflows /workspace/crestfall-comfy-service-assets/workflows

RUN test -f /ComfyUI/main.py && \
    test -f /ComfyUI/comfy/ldm/models/autoencoder.py && \
    chmod +x /workspace/crestfall-comfy-worker/start.sh

CMD ["/bin/bash", "-lc", "/workspace/crestfall-comfy-worker/start.sh"]
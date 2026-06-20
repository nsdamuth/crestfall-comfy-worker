FROM runpod/worker-comfyui:5.8.6-base

USER root

RUN command -v git >/dev/null 2>&1 || (apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*)

# Guarantee ComfyUI exists at the path start.sh expects.
RUN if [ ! -f "/ComfyUI/main.py" ]; then \
      rm -rf /ComfyUI && \
      git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI; \
    fi

RUN python3 -m pip install --no-cache-dir -r /ComfyUI/requirements.txt

# Required custom nodes for the exported workflows.
RUN mkdir -p /ComfyUI/custom_nodes && \
    if [ ! -d "/ComfyUI/custom_nodes/comfyui_ipadapter_plus" ]; then \
      git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git /ComfyUI/custom_nodes/comfyui_ipadapter_plus; \
    fi && \
    if [ -f "/ComfyUI/custom_nodes/comfyui_ipadapter_plus/requirements.txt" ]; then \
      python3 -m pip install --no-cache-dir -r /ComfyUI/custom_nodes/comfyui_ipadapter_plus/requirements.txt; \
    fi

RUN mkdir -p /ComfyUI/custom_nodes && \
    if [ ! -d "/ComfyUI/custom_nodes/ComfyUI-KJNodes" ]; then \
      git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git /ComfyUI/custom_nodes/ComfyUI-KJNodes; \
    fi && \
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

RUN test -f /ComfyUI/main.py
RUN chmod +x /workspace/crestfall-comfy-worker/start.sh

CMD ["/bin/bash", "-lc", "/workspace/crestfall-comfy-worker/start.sh"]
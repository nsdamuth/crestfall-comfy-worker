FROM runpod/worker-comfyui:5.8.6-base

USER root

WORKDIR /workspace/crestfall-comfy-worker

COPY requirements.txt /workspace/crestfall-comfy-worker/requirements.txt
RUN python3 -m pip install --no-cache-dir -r /workspace/crestfall-comfy-worker/requirements.txt

# Crestfall worker code
COPY handler.py /workspace/crestfall-comfy-worker/handler.py
COPY local_comfy_worker.py /workspace/crestfall-comfy-worker/local_comfy_worker.py
COPY workflow_registry.py /workspace/crestfall-comfy-worker/workflow_registry.py
COPY start.sh /workspace/crestfall-comfy-worker/start.sh
COPY rp_handler.py /workspace/crestfall-comfy-worker/rp_handler.py

# Crestfall workflows only. Models stay on the RunPod volume.
COPY workflows /workspace/crestfall-comfy-service-assets/workflows

# IPAdapter custom node. If the base image already has it, this is harmlessly skipped.
RUN if [ ! -d "/ComfyUI/custom_nodes/comfyui_ipadapter_plus" ] && [ -d "/ComfyUI/custom_nodes" ]; then \
      git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git /ComfyUI/custom_nodes/comfyui_ipadapter_plus; \
    fi

RUN chmod +x /workspace/crestfall-comfy-worker/start.sh

CMD ["/bin/bash", "-lc", "/workspace/crestfall-comfy-worker/start.sh"]
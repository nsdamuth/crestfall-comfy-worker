#!/usr/bin/env bash
set -euo pipefail

echo "[crestfall-worker] starting"

export COMFY_BASE_URL="${COMFY_BASE_URL:-http://127.0.0.1:8188}"
export CRESTFALL_ASSETS="${CRESTFALL_ASSETS:-/workspace/crestfall-comfy-service-assets}"
export CRESTFALL_WORKER_TMP_DIR="${CRESTFALL_WORKER_TMP_DIR:-/tmp/crestfall-comfy-worker}"
export TEST_OUTPUT_DIR="${TEST_OUTPUT_DIR:-/tmp/crestfall-comfy-worker/test_outputs}"

find_comfy_dir() {
  if [ -n "${COMFY_DIR:-}" ] && [ -f "$COMFY_DIR/main.py" ]; then
    echo "$COMFY_DIR"
    return 0
  fi

  if [ -f "/runpod-volume/runpod-slim/ComfyUI/main.py" ]; then
    echo "/runpod-volume/runpod-slim/ComfyUI"
    return 0
  fi

  if [ -f "/workspace/runpod-slim/ComfyUI/main.py" ]; then
    echo "/workspace/runpod-slim/ComfyUI"
    return 0
  fi

  FOUND="$(find / -maxdepth 5 -type f -path "*/ComfyUI/main.py" 2>/dev/null | head -n 1 || true)"

  if [ -n "$FOUND" ]; then
    dirname "$FOUND"
    return 0
  fi

  return 1
}

export COMFY_DIR="$(find_comfy_dir)"

echo "[crestfall-worker] COMFY_DIR=$COMFY_DIR"
echo "[crestfall-worker] CRESTFALL_ASSETS=$CRESTFALL_ASSETS"

mkdir -p "$CRESTFALL_WORKER_TMP_DIR"
mkdir -p "$TEST_OUTPUT_DIR"
mkdir -p "$COMFY_DIR/input"
mkdir -p "$COMFY_DIR/output"

echo "[crestfall-worker] checking workflow assets"
find "$CRESTFALL_ASSETS/workflows" -type f -name "*.json" | sort

echo "[crestfall-worker] checking required model files"
check_model() {
  NAME="$1"
  FOUND="$(find "$COMFY_DIR/models" -type f -name "$NAME" 2>/dev/null | head -n 1 || true)"
  if [ -z "$FOUND" ]; then
    echo "[crestfall-worker] MISSING MODEL: $NAME"
    exit 1
  fi
  echo "[crestfall-worker] OK: $FOUND"
}

check_model "ponyDiffusionV6XL_v6StartWithThisOne.safetensors"
check_model "sd_xl_base_1.0.safetensors"
check_model "DreamShaper_8_pruned.safetensors"
check_model "RealVisXL_V5.0_fp16.safetensors"
check_model "ip-adapter_sdxl_vit-h.safetensors"
check_model "ip-adapter_sd15.safetensors"
check_model "CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
check_model "8x_NMKD-Superscale_150000_G.pth"
check_model "8x_NMKD-Faces_160000_G.pth"
check_model "4x-AnimeSharp.pth"

echo "[crestfall-worker] cleanup stale temp files"
find "$COMFY_DIR/input" -maxdepth 1 -type f -name "crestfall_ref_*" -mmin +120 -delete || true
find "$COMFY_DIR/output" -type f -name "crestfall_*" -mmin +120 -delete || true

echo "[crestfall-worker] launching ComfyUI"
cd "$COMFY_DIR"
python3 main.py --listen 127.0.0.1 --port 8188 > /tmp/crestfall-comfyui.log 2>&1 &

COMFY_PID=$!

echo "[crestfall-worker] waiting for ComfyUI, pid=$COMFY_PID"

for i in $(seq 1 120); do
  if curl -fsS "$COMFY_BASE_URL/system_stats" >/dev/null 2>&1; then
    echo "[crestfall-worker] ComfyUI is ready"
    break
  fi

  if ! kill -0 "$COMFY_PID" >/dev/null 2>&1; then
    echo "[crestfall-worker] ComfyUI exited early"
    cat /tmp/crestfall-comfyui.log || true
    exit 1
  fi

  sleep 2
done

if ! curl -fsS "$COMFY_BASE_URL/system_stats" >/dev/null 2>&1; then
  echo "[crestfall-worker] ComfyUI did not become ready"
  cat /tmp/crestfall-comfyui.log || true
  exit 1
fi

echo "[crestfall-worker] starting RunPod handler"
cd /workspace/crestfall-comfy-worker
python3 rp_handler.py
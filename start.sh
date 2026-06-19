#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  echo "[crestfall-worker] ERROR at line ${1:-unknown}"
  echo "[crestfall-worker] pwd=$(pwd)"
  echo "[crestfall-worker] COMFY_SOURCE_DIR=${COMFY_SOURCE_DIR:-}"
  echo "[crestfall-worker] COMFY_MODEL_SOURCE_DIR=${COMFY_MODEL_SOURCE_DIR:-}"
  echo "[crestfall-worker] COMFY_DIR=${COMFY_DIR:-}"
  echo "[crestfall-worker] recent ComfyUI log:"
  cat /tmp/crestfall-comfyui.log 2>/dev/null || true
}

trap 'on_error $LINENO' ERR

echo "[crestfall-worker] starting"

export COMFY_SOURCE_DIR="${COMFY_SOURCE_DIR:-/runpod-volume/runpod-slim/ComfyUI}"
export COMFY_MODEL_SOURCE_DIR="${COMFY_MODEL_SOURCE_DIR:-/runpod-volume/runpod-slim/ComfyUI/models}"
export COMFY_DIR="${COMFY_DIR:-/tmp/crestfall-comfy-runtime/ComfyUI}"
export COMFY_BASE_URL="${COMFY_BASE_URL:-http://127.0.0.1:8188}"
export CRESTFALL_ASSETS="${CRESTFALL_ASSETS:-/workspace/crestfall-comfy-service-assets}"
export CRESTFALL_WORKER_TMP_DIR="${CRESTFALL_WORKER_TMP_DIR:-/tmp/crestfall-comfy-worker}"
export TEST_OUTPUT_DIR="${TEST_OUTPUT_DIR:-/tmp/crestfall-comfy-worker/test_outputs}"

echo "[crestfall-worker] COMFY_SOURCE_DIR=$COMFY_SOURCE_DIR"
echo "[crestfall-worker] COMFY_MODEL_SOURCE_DIR=$COMFY_MODEL_SOURCE_DIR"
echo "[crestfall-worker] COMFY_DIR=$COMFY_DIR"
echo "[crestfall-worker] CRESTFALL_ASSETS=$CRESTFALL_ASSETS"

if [ ! -f "$COMFY_SOURCE_DIR/main.py" ]; then
  echo "[crestfall-worker] MISSING COMFY SOURCE: $COMFY_SOURCE_DIR/main.py"
  exit 1
fi

if [ ! -d "$COMFY_MODEL_SOURCE_DIR" ]; then
  echo "[crestfall-worker] MISSING MODEL SOURCE DIR: $COMFY_MODEL_SOURCE_DIR"
  exit 1
fi

mkdir -p "$CRESTFALL_WORKER_TMP_DIR"
mkdir -p "$TEST_OUTPUT_DIR"

echo "[crestfall-worker] building isolated Comfy runtime"

rm -rf "$COMFY_DIR"
mkdir -p "$(dirname "$COMFY_DIR")"

python3 - <<'PY'
import os
import shutil
from pathlib import Path

source = Path(os.environ["COMFY_SOURCE_DIR"])
target = Path(os.environ["COMFY_DIR"])

excluded_dirs = {
    ".git",
    ".venv",
    ".venv-cu128",
    "__pycache__",
    "models",
    "user",
    "input",
    "output",
    "temp",
    "custom_nodes",
}

def ignore_function(directory, names):
    ignored = set()
    for name in names:
        if name in excluded_dirs:
            ignored.add(name)
        if name.endswith(".pyc"):
            ignored.add(name)
    return ignored

shutil.copytree(
    source,
    target,
    ignore=ignore_function,
    dirs_exist_ok=True,
    symlinks=True,
)

target_custom_nodes = target / "custom_nodes"
target_custom_nodes.mkdir(parents=True, exist_ok=True)

source_custom_nodes = source / "custom_nodes"

# Keep only the custom nodes needed by the approved Crestfall workflows.
# Do not copy ComfyUI-Manager or Civicomfy into the service runtime.
needed_custom_nodes = [
    "comfyui_ipadapter_plus",
    "ComfyUI_IPAdapter_plus",
    "ComfyUI-KJNodes",
]

for name in needed_custom_nodes:
    src = source_custom_nodes / name
    dst = target_custom_nodes / name

    if not src.exists():
        continue

    if src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=True, symlinks=True)
    else:
        shutil.copy2(src, dst)

print(f"[crestfall-worker] isolated runtime copied to {target}")
PY

mkdir -p "$COMFY_DIR/input"
mkdir -p "$COMFY_DIR/output"
mkdir -p "$COMFY_DIR/models"

echo "[crestfall-worker] linking model directories"

link_model_dir() {
  NAME="$1"
  SOURCE="$COMFY_MODEL_SOURCE_DIR/$NAME"
  TARGET="$COMFY_DIR/models/$NAME"

  if [ ! -d "$SOURCE" ]; then
    echo "[crestfall-worker] MISSING MODEL DIR: $SOURCE"
    exit 1
  fi

  if [ "$SOURCE" = "$TARGET" ]; then
    echo "[crestfall-worker] REFUSING self-link: SOURCE and TARGET are the same path: $SOURCE"
    exit 1
  fi

  rm -rf "$TARGET"
  ln -s "$SOURCE" "$TARGET"

  echo "[crestfall-worker] linked $TARGET -> $SOURCE"
}

link_model_dir "checkpoints"
link_model_dir "ipadapter"
link_model_dir "clip_vision"
link_model_dir "upscale_models"

echo "[crestfall-worker] checking workflow assets"
find "$CRESTFALL_ASSETS/workflows" -type f -name "*.json" | sort

echo "[crestfall-worker] checking required model files"

check_model() {
  NAME="$1"
  FOUND="$(find -L "$COMFY_DIR/models" -type f -name "$NAME" 2>/dev/null | head -n 1 || true)"

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

python3 -u main.py \
  --listen 127.0.0.1 \
  --port 8188 \
  --user-directory "$CRESTFALL_WORKER_TMP_DIR/comfy-user" \
  --database-url "sqlite:///$CRESTFALL_WORKER_TMP_DIR/comfyui.db" \
  > /tmp/crestfall-comfyui.log 2>&1 &

COMFY_PID=$!

echo "[crestfall-worker] waiting for ComfyUI, pid=$COMFY_PID"

for i in $(seq 1 180); do
  if curl -fsS "$COMFY_BASE_URL/system_stats" >/dev/null 2>&1; then
    echo "[crestfall-worker] ComfyUI is ready"
    break
  fi

  if ! kill -0 "$COMFY_PID" >/dev/null 2>&1; then
    echo "[crestfall-worker] ComfyUI exited early"
    cat /tmp/crestfall-comfyui.log || true
    exit 1
  fi

  if [ "$((i % 10))" -eq 0 ]; then
    echo "[crestfall-worker] still waiting for ComfyUI after $((i * 2)) seconds"
    echo "[crestfall-worker] recent ComfyUI log:"
    tail -n 80 /tmp/crestfall-comfyui.log || true
  fi

  sleep 2
done

if ! curl -fsS "$COMFY_BASE_URL/system_stats" >/dev/null 2>&1; then
  echo "[crestfall-worker] ComfyUI did not become ready"
  echo "[crestfall-worker] final ComfyUI log:"
  cat /tmp/crestfall-comfyui.log || true
  exit 1
fi

echo "[crestfall-worker] starting RunPod handler"

cd /workspace/crestfall-comfy-worker
python3 rp_handler.py
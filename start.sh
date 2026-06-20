#!/usr/bin/env bash
set -euo pipefail

echo "[crestfall-worker] starting"

export MODEL_SOURCE_MODE="${MODEL_SOURCE_MODE:-volume}"
export MODEL_LOCAL_DIR="${MODEL_LOCAL_DIR:-/workspace/crestfall-comfy-models}"

export COMFY_SOURCE_DIR="${COMFY_SOURCE_DIR:-/ComfyUI}"
export COMFY_MODEL_SOURCE_DIR="${COMFY_MODEL_SOURCE_DIR:-$MODEL_LOCAL_DIR}"
export COMFY_DIR="${COMFY_DIR:-/tmp/crestfall-comfy-runtime/ComfyUI}"

export CRESTFALL_ASSETS="${CRESTFALL_ASSETS:-/workspace/crestfall-comfy-service-assets}"
export COMFY_BASE_URL="${COMFY_BASE_URL:-http://127.0.0.1:8188}"
export CRESTFALL_WORKER_TMP_DIR="${CRESTFALL_WORKER_TMP_DIR:-/tmp/crestfall-comfy-worker}"
export TEST_OUTPUT_DIR="${TEST_OUTPUT_DIR:-$CRESTFALL_WORKER_TMP_DIR/test_outputs}"

echo "[crestfall-worker] COMFY_SOURCE_DIR=$COMFY_SOURCE_DIR"
echo "[crestfall-worker] COMFY_MODEL_SOURCE_DIR=$COMFY_MODEL_SOURCE_DIR"
echo "[crestfall-worker] COMFY_DIR=$COMFY_DIR"
echo "[crestfall-worker] CRESTFALL_ASSETS=$CRESTFALL_ASSETS"
echo "[crestfall-worker] COMFY_BASE_URL=$COMFY_BASE_URL"
echo "[crestfall-worker] MODEL_SOURCE_MODE=$MODEL_SOURCE_MODE"
echo "[crestfall-worker] MODEL_LOCAL_DIR=$MODEL_LOCAL_DIR"
echo "[crestfall-worker] CRESTFALL_WORKER_TMP_DIR=$CRESTFALL_WORKER_TMP_DIR"
echo "[crestfall-worker] TEST_OUTPUT_DIR=$TEST_OUTPUT_DIR"

case "$COMFY_DIR" in
  /runpod-volume/*|/workspace/runpod-slim/*)
    echo "[crestfall-worker] REFUSING to use mounted persistent storage as writable COMFY_DIR: $COMFY_DIR"
    exit 1
    ;;
esac

if [ ! -f "$COMFY_SOURCE_DIR/main.py" ]; then
  echo "[crestfall-worker] MISSING COMFY SOURCE: $COMFY_SOURCE_DIR/main.py"
  exit 1
fi

if [ ! -f "$COMFY_SOURCE_DIR/comfy/ldm/models/autoencoder.py" ]; then
  echo "[crestfall-worker] MISSING COMFY SOURCE PACKAGE: $COMFY_SOURCE_DIR/comfy/ldm/models/autoencoder.py"
  echo "[crestfall-worker] This means the Docker image does not contain a complete ComfyUI source tree."
  exit 1
fi

if [ "$MODEL_SOURCE_MODE" = "r2" ]; then
  echo "[crestfall-worker] syncing models from R2"
  python3 /workspace/crestfall-comfy-worker/model_sync.py
  export COMFY_MODEL_SOURCE_DIR="$MODEL_LOCAL_DIR"
elif [ "$MODEL_SOURCE_MODE" = "volume" ]; then
  echo "[crestfall-worker] using mounted model volume"
else
  echo "[crestfall-worker] Unsupported MODEL_SOURCE_MODE: $MODEL_SOURCE_MODE"
  echo "[crestfall-worker] Expected MODEL_SOURCE_MODE=volume or MODEL_SOURCE_MODE=r2"
  exit 1
fi

if [ ! -d "$COMFY_MODEL_SOURCE_DIR" ]; then
  echo "[crestfall-worker] MISSING MODEL SOURCE DIR: $COMFY_MODEL_SOURCE_DIR"
  exit 1
fi

echo "[crestfall-worker] preparing worker directories"
mkdir -p "$CRESTFALL_WORKER_TMP_DIR"
mkdir -p "$TEST_OUTPUT_DIR"

echo "[crestfall-worker] building isolated Comfy runtime"
rm -rf "$COMFY_DIR"
mkdir -p "$(dirname "$COMFY_DIR")"

python3 - <<'PY'
import os
import shutil
from pathlib import Path

source = Path(os.environ["COMFY_SOURCE_DIR"]).resolve()
target = Path(os.environ["COMFY_DIR"]).resolve()

# Only exclude top-level runtime/state/model folders directly under /ComfyUI.
# Do NOT globally exclude every folder named "models", because Comfy's source code contains:
# /ComfyUI/comfy/ldm/models/
top_level_excluded_dirs = {
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
    directory_path = Path(directory).resolve()
    ignored = set()

    if directory_path == source:
        for name in names:
            if name in top_level_excluded_dirs:
                ignored.add(name)

    for name in names:
        if name == "__pycache__" or name.endswith(".pyc"):
            ignored.add(name)

    return ignored

shutil.copytree(
    source,
    target,
    ignore=ignore_function,
    dirs_exist_ok=True,
    symlinks=True,
)

required_files = [
    target / "main.py",
    target / "comfy" / "sd.py",
    target / "comfy" / "ldm" / "models" / "autoencoder.py",
]

for required_file in required_files:
    if not required_file.exists():
        raise RuntimeError(f"Isolated runtime missing required file: {required_file}")

target_custom_nodes = target / "custom_nodes"
target_custom_nodes.mkdir(parents=True, exist_ok=True)

source_custom_nodes = source / "custom_nodes"

needed_custom_nodes = [
    "comfyui_ipadapter_plus",
    "ComfyUI_IPAdapter_plus",
    "ComfyUI-KJNodes",
]

for name in needed_custom_nodes:
    src = source_custom_nodes / name
    dst = target_custom_nodes / name

    if not src.exists():
        print(f"[crestfall-worker] custom node not found in source, skipping: {src}")
        continue

    if dst.exists():
        if dst.is_dir():
            shutil.rmtree(dst)
        else:
            dst.unlink()

    if src.is_dir():
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst)

print(f"[crestfall-worker] isolated runtime copied to {target}")
PY

echo "[crestfall-worker] linking model directories"

mkdir -p "$COMFY_DIR/models"

link_model_dir () {
  NAME="$1"
  SOURCE="$COMFY_MODEL_SOURCE_DIR/$NAME"
  TARGET="$COMFY_DIR/models/$NAME"

  if [ ! -d "$SOURCE" ]; then
    echo "[crestfall-worker] MISSING MODEL DIR: $SOURCE"
    exit 1
  fi

  case "$TARGET" in
    /runpod-volume/*|/workspace/runpod-slim/*)
      echo "[crestfall-worker] REFUSING to write model link inside mounted persistent storage: $TARGET"
      exit 1
      ;;
  esac

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

WORKFLOW_ROOT="$CRESTFALL_ASSETS/workflows"

if [ ! -d "$WORKFLOW_ROOT" ]; then
  echo "[crestfall-worker] MISSING WORKFLOW ROOT: $WORKFLOW_ROOT"
  exit 1
fi

find "$WORKFLOW_ROOT" -type f -name "*.json" | sort

WORKFLOW_COUNT="$(find "$WORKFLOW_ROOT" -type f -name "*.json" | wc -l | tr -d ' ')"

if [ "$WORKFLOW_COUNT" -lt 9 ]; then
  echo "[crestfall-worker] Expected at least 9 workflow json files, found $WORKFLOW_COUNT"
  exit 1
fi

python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["CRESTFALL_ASSETS"]) / "workflows"
bad = []

for path in sorted(root.rglob("*.json")):
    try:
        json.loads(path.read_text())
    except Exception as error:
        bad.append((path, error))

if bad:
    for path, error in bad:
        print(f"[crestfall-worker] BAD WORKFLOW JSON: {path} -> {error}")
    raise SystemExit(1)

print("[crestfall-worker] workflow JSON validation passed")
PY

echo "[crestfall-worker] checking required model files"

check_required_file () {
  RELATIVE_PATH="$1"
  FULL_PATH="$COMFY_DIR/models/$RELATIVE_PATH"

  if [ ! -f "$FULL_PATH" ]; then
    echo "[crestfall-worker] MISSING REQUIRED FILE: $FULL_PATH"
    exit 1
  fi

  SIZE_BYTES="$(stat -c%s "$FULL_PATH" 2>/dev/null || echo 0)"

  if [ "$SIZE_BYTES" -le 1024 ]; then
    echo "[crestfall-worker] BAD REQUIRED FILE SIZE: $FULL_PATH is only $SIZE_BYTES bytes"
    exit 1
  fi

  echo "[crestfall-worker] OK: $FULL_PATH"
}

check_required_file "checkpoints/ponyDiffusionV6XL_v6StartWithThisOne.safetensors"
check_required_file "checkpoints/sd_xl_base_1.0.safetensors"
check_required_file "checkpoints/DreamShaper_8_pruned.safetensors"
check_required_file "checkpoints/RealVisXL_V5.0_fp16.safetensors"

check_required_file "ipadapter/ip-adapter_sdxl_vit-h.safetensors"
check_required_file "ipadapter/ip-adapter_sd15.safetensors"

check_required_file "clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"

check_required_file "upscale_models/8x_NMKD-Superscale_150000_G.pth"
check_required_file "upscale_models/8x_NMKD-Faces_160000_G.pth"
check_required_file "upscale_models/4x-AnimeSharp.pth"

echo "[crestfall-worker] cleanup stale temp files"

rm -rf "$COMFY_DIR/input" "$COMFY_DIR/output" "$COMFY_DIR/temp"
mkdir -p "$COMFY_DIR/input" "$COMFY_DIR/output" "$COMFY_DIR/temp"

echo "[crestfall-worker] preparing Comfy runtime directories"

mkdir -p "$CRESTFALL_WORKER_TMP_DIR/comfy-user"
mkdir -p "$TEST_OUTPUT_DIR"
mkdir -p "$COMFY_DIR/input"
mkdir -p "$COMFY_DIR/output"
mkdir -p "$COMFY_DIR/temp"

echo "[crestfall-worker] launching ComfyUI"

cd "$COMFY_DIR"

python3 -u main.py \
  --listen 127.0.0.1 \
  --port 8188 \
  --user-directory "$CRESTFALL_WORKER_TMP_DIR/comfy-user" \
  --database-url "sqlite:///$CRESTFALL_WORKER_TMP_DIR/comfyui.db" \
  --input-directory "$COMFY_DIR/input" \
  --output-directory "$COMFY_DIR/output" \
  --temp-directory "$COMFY_DIR/temp" \
  > /tmp/crestfall-comfyui.log 2>&1 &

COMFY_PID="$!"

echo "[crestfall-worker] waiting for ComfyUI, pid=$COMFY_PID"

for i in $(seq 1 120); do
  if ! kill -0 "$COMFY_PID" 2>/dev/null; then
    echo "[crestfall-worker] ComfyUI exited early"
    tail -n 240 /tmp/crestfall-comfyui.log || true
    exit 1
  fi

  if python3 - <<'PY'
import os
import urllib.request

base_url = os.environ.get("COMFY_BASE_URL", "http://127.0.0.1:8188").rstrip("/")
try:
    with urllib.request.urlopen(f"{base_url}/system_stats", timeout=2) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
  then
    echo "[crestfall-worker] ComfyUI is ready"
    break
  fi

  if [ "$i" -eq 120 ]; then
    echo "[crestfall-worker] Timed out waiting for ComfyUI"
    tail -n 240 /tmp/crestfall-comfyui.log || true
    exit 1
  fi

  if [ $((i % 10)) -eq 0 ]; then
    echo "[crestfall-worker] still waiting for ComfyUI..."
    tail -n 40 /tmp/crestfall-comfyui.log || true
  fi

  sleep 2
done

echo "[crestfall-worker] starting RunPod handler"

cd /workspace/crestfall-comfy-worker
exec python3 -u rp_handler.py
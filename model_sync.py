import os
import sys
from pathlib import Path

import boto3
from botocore.config import Config


REQUIRED_MODELS = [
    "checkpoints/ponyDiffusionV6XL_v6StartWithThisOne.safetensors",
    "checkpoints/sd_xl_base_1.0.safetensors",
    "checkpoints/DreamShaper_8_pruned.safetensors",
    "checkpoints/RealVisXL_V5.0_fp16.safetensors",
    "ipadapter/ip-adapter_sdxl_vit-h.safetensors",
    "ipadapter/ip-adapter_sd15.safetensors",
    "clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors",
    "upscale_models/8x_NMKD-Superscale_150000_G.pth",
    "upscale_models/8x_NMKD-Faces_160000_G.pth",
    "upscale_models/4x-AnimeSharp.pth",
]


def require_env(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def main():
    bucket = require_env("R2_MODEL_BUCKET")
    endpoint_url = require_env("R2_MODEL_ENDPOINT")
    access_key_id = require_env("AWS_ACCESS_KEY_ID")
    secret_access_key = require_env("AWS_SECRET_ACCESS_KEY")

    prefix = os.environ.get("R2_MODEL_PREFIX", "comfy/models").strip("/")
    local_dir = Path(os.environ.get("MODEL_LOCAL_DIR", "/workspace/crestfall-comfy-models"))

    print(f"[crestfall-model-sync] bucket={bucket}")
    print(f"[crestfall-model-sync] prefix={prefix}")
    print(f"[crestfall-model-sync] local_dir={local_dir}")

    local_dir.mkdir(parents=True, exist_ok=True)

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint_url,
        aws_access_key_id=access_key_id,
        aws_secret_access_key=secret_access_key,
        region_name=os.environ.get("AWS_DEFAULT_REGION", "auto"),
        config=Config(signature_version="s3v4"),
    )

    for relative_path in REQUIRED_MODELS:
        key = f"{prefix}/{relative_path}"
        destination = local_dir / relative_path
        temp_destination = destination.with_suffix(destination.suffix + ".part")

        destination.parent.mkdir(parents=True, exist_ok=True)

        head = s3.head_object(Bucket=bucket, Key=key)
        expected_size = int(head["ContentLength"])

        if destination.exists() and destination.stat().st_size == expected_size:
            print(f"[crestfall-model-sync] OK cached: {relative_path} ({expected_size} bytes)")
            continue

        print(f"[crestfall-model-sync] downloading: s3://{bucket}/{key}")
        print(f"[crestfall-model-sync] destination: {destination}")

        if temp_destination.exists():
            temp_destination.unlink()

        s3.download_file(bucket, key, str(temp_destination))

        actual_size = temp_destination.stat().st_size
        if actual_size != expected_size:
            raise RuntimeError(
                f"Bad download size for {relative_path}: expected {expected_size}, got {actual_size}"
            )

        temp_destination.replace(destination)
        print(f"[crestfall-model-sync] OK downloaded: {relative_path} ({actual_size} bytes)")

    print("[crestfall-model-sync] all required models are present")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[crestfall-model-sync] ERROR: {error}", file=sys.stderr)
        raise
import base64
import json
import os
import shutil
import uuid
from pathlib import Path
from types import SimpleNamespace

try:
    import runpod
except Exception:
    runpod = None

from local_comfy_worker import run_job


WORKER_TMP_DIR = Path(
    os.environ.get(
        "CRESTFALL_WORKER_TMP_DIR",
        "/workspace/crestfall-comfy-worker/tmp",
    )
)

WORKER_TMP_DIR.mkdir(parents=True, exist_ok=True)


def normalize_event_input(event):
    if isinstance(event, dict) and isinstance(event.get("input"), dict):
        return event["input"]

    if isinstance(event, dict):
        return event

    return {}


def normalize_string(value, fallback=""):
    if isinstance(value, str) and value.strip():
        return value.strip()

    return fallback


def normalize_int(value, fallback):
    try:
        parsed = int(value)
    except Exception:
        return fallback

    return parsed


def normalize_seed(value):
    if value is None or value == "":
        return None

    try:
        return int(value)
    except Exception:
        return None


def strip_data_uri(value):
    if not isinstance(value, str):
        return ""

    if "," in value and value.strip().lower().startswith("data:"):
        return value.split(",", 1)[1]

    return value.strip()


def extension_from_mime_type(mime_type):
    normalized = normalize_string(mime_type).lower()

    if normalized == "image/jpeg":
        return ".jpg"

    if normalized == "image/webp":
        return ".webp"

    return ".png"


def write_reference_image(input_payload, job_id):
    reference_path = normalize_string(
        input_payload.get("referenceImagePath")
        or input_payload.get("reference_image_path")
    )

    if reference_path:
        return reference_path, None

    reference_image = input_payload.get("referenceImage") or input_payload.get(
        "reference_image"
    )

    if not isinstance(reference_image, dict):
        return None, None

    encoded = strip_data_uri(
        reference_image.get("base64")
        or reference_image.get("data")
        or reference_image.get("imageBase64")
    )

    if not encoded:
        return None, None

    mime_type = normalize_string(reference_image.get("mimeType"), "image/png")
    suffix = extension_from_mime_type(mime_type)
    filename = f"worker_ref_{job_id}{suffix}"
    destination = WORKER_TMP_DIR / filename

    destination.write_bytes(base64.b64decode(encoded))

    return str(destination), destination


def encode_output_file(path):
    output_path = Path(path)
    suffix = output_path.suffix.lower()

    if suffix in [".jpg", ".jpeg"]:
        mime_type = "image/jpeg"
    elif suffix == ".webp":
        mime_type = "image/webp"
    else:
        mime_type = "image/png"

    return {
        "filename": output_path.name,
        "mimeType": mime_type,
        "base64": base64.b64encode(output_path.read_bytes()).decode("ascii"),
    }


def remove_empty_parent(path):
    try:
        parent = Path(path).parent
        parent.rmdir()
    except Exception:
        pass


def handler(event):
    input_payload = normalize_event_input(event)
    job_id = str(uuid.uuid4())[:12]

    render_family = normalize_string(
        input_payload.get("renderFamily")
        or input_payload.get("render_family"),
        "FANTASY",
    )

    reference_mode = normalize_string(
        input_payload.get("referenceMode")
        or input_payload.get("reference_mode"),
        "auto",
    ).lower()

    prompt = normalize_string(
        input_payload.get("positivePrompt")
        or input_payload.get("positive_prompt")
        or input_payload.get("prompt"),
        "masterpiece, best quality, polished character art",
    )

    negative_prompt = normalize_string(
        input_payload.get("negativePrompt")
        or input_payload.get("negative_prompt"),
        "worst quality, low quality, blurry, bad anatomy, bad hands, text, watermark, logo",
    )

    width = normalize_int(input_payload.get("width"), 512)
    height = normalize_int(input_payload.get("height"), 768)
    batch_size = normalize_int(
        input_payload.get("batchSize") or input_payload.get("batch_size"),
        1,
    )
    seed = normalize_seed(input_payload.get("seed"))

    return_images = bool(input_payload.get("returnImages", True))
    debug_preserve_outputs = bool(input_payload.get("debugPreserveOutputs", False))

    temp_reference_path = None

    try:
        reference_image_path, temp_reference_path = write_reference_image(
            input_payload,
            job_id,
        )

        args = SimpleNamespace(
            render_family=render_family,
            reference_mode=reference_mode,
            reference_image=reference_image_path,
            prompt=prompt,
            negative_prompt=negative_prompt,
            width=width,
            height=height,
            batch_size=batch_size,
            seed=seed,
            cleanup_comfy_output=True,
            cleanup_reference_input=True,
        )

        result = run_job(args)

        images = []

        if return_images:
            images = [encode_output_file(path) for path in result.get("saved_files", [])]

        response = {
            "ok": True,
            "jobId": result.get("job_id"),
            "promptId": result.get("prompt_id"),
            "renderFamily": result.get("render_family"),
            "useReference": result.get("use_reference"),
            "savedFiles": result.get("saved_files", []),
            "images": images,
        }

        if not debug_preserve_outputs:
            for saved_file in result.get("saved_files", []):
                try:
                    Path(saved_file).unlink()
                    remove_empty_parent(saved_file)
                except FileNotFoundError:
                    pass

        return response

    finally:
        if temp_reference_path:
            try:
                temp_reference_path.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    if runpod is None:
        raise RuntimeError(
            "runpod package is not installed. Install it before running handler.py directly as a serverless worker."
        )

    runpod.serverless.start({"handler": handler})

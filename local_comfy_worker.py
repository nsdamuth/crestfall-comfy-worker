import argparse
import base64
import json
import os
import random
import shutil
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from workflow_registry import select_workflow

COMFY_DIR = Path(os.environ.get("COMFY_DIR", "/workspace/runpod-slim/ComfyUI"))
COMFY_BASE_URL = os.environ.get("COMFY_BASE_URL", "http://127.0.0.1:8188").rstrip("/")
TEST_OUTPUT_DIR = Path(os.environ.get("TEST_OUTPUT_DIR", "/workspace/crestfall-comfy-worker/test_outputs"))


def http_json(method, path, payload=None, timeout=30):
    url = f"{COMFY_BASE_URL}{path}"
    data = None

    headers = {
        "Content-Type": "application/json",
    }

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(url, data=data, headers=headers, method=method)

    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8")
        return json.loads(body) if body else {}


def patch_text_nodes(workflow, node_ids, text):
    for node_id in node_ids:
        if node_id not in workflow:
            raise KeyError(f"Prompt node missing from workflow: {node_id}")
        workflow[node_id]["inputs"]["text"] = text


def patch_latent_node(workflow, node_id, width, height, batch_size):
    if not node_id or node_id not in workflow:
        return

    inputs = workflow[node_id].setdefault("inputs", {})
    inputs["width"] = int(width)
    inputs["height"] = int(height)
    inputs["batch_size"] = int(batch_size)


def patch_sampler_nodes(workflow, node_ids, seed):
    if seed is None:
        seed = random.randint(1, 2**63 - 1)

    used_seeds = []

    for index, node_id in enumerate(node_ids):
        if node_id not in workflow:
            raise KeyError(f"Sampler node missing from workflow: {node_id}")

        node_seed = int(seed) + index
        workflow[node_id]["inputs"]["seed"] = node_seed
        used_seeds.append(node_seed)

    return used_seeds


def patch_save_node(workflow, node_id, filename_prefix):
    if node_id not in workflow:
        raise KeyError(f"SaveImage node missing from workflow: {node_id}")

    workflow[node_id]["inputs"]["filename_prefix"] = filename_prefix


def copy_reference_image(reference_image_path, job_id):
    if not reference_image_path:
        return None

    source = Path(reference_image_path)

    if not source.exists():
        raise FileNotFoundError(f"Reference image does not exist: {source}")

    suffix = source.suffix.lower() or ".png"
    filename = f"crestfall_ref_{job_id}{suffix}"
    destination = COMFY_DIR / "input" / filename

    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(source, destination)

    return filename


def patch_reference_image(workflow, node_id, reference_filename):
    if not node_id:
        raise ValueError("Workflow config does not define a reference image node.")

    if node_id not in workflow:
        raise KeyError(f"Reference LoadImage node missing from workflow: {node_id}")

    workflow[node_id]["inputs"]["image"] = reference_filename


def submit_prompt(workflow):
    client_id = str(uuid.uuid4())

    response = http_json(
        "POST",
        "/prompt",
        {
            "prompt": workflow,
            "client_id": client_id,
        },
        timeout=30,
    )

    prompt_id = response.get("prompt_id")

    if not prompt_id:
        raise RuntimeError(f"Comfy did not return prompt_id: {response}")

    return prompt_id


def wait_for_prompt(prompt_id, timeout_seconds=900, poll_seconds=2):
    started_at = time.time()

    while True:
        history = http_json("GET", f"/history/{prompt_id}", timeout=30)

        if prompt_id in history:
            entry = history[prompt_id]
            status = entry.get("status", {})
            status_str = status.get("status_str")

            if status_str == "error":
                raise RuntimeError(f"Comfy workflow failed: {json.dumps(status, indent=2)}")

            return entry

        if time.time() - started_at > timeout_seconds:
            raise TimeoutError(f"Timed out waiting for Comfy prompt: {prompt_id}")

        time.sleep(poll_seconds)


def download_output_image(image_info, destination_dir):
    filename = image_info["filename"]
    subfolder = image_info.get("subfolder") or ""
    image_type = image_info.get("type") or "output"

    query = urllib.parse.urlencode(
        {
            "filename": filename,
            "subfolder": subfolder,
            "type": image_type,
        }
    )

    url = f"{COMFY_BASE_URL}/view?{query}"

    destination_dir.mkdir(parents=True, exist_ok=True)
    destination = destination_dir / filename

    with urllib.request.urlopen(url, timeout=120) as response:
        destination.write_bytes(response.read())

    return destination


def collect_images(history_entry):
    outputs = history_entry.get("outputs", {})
    images = []

    for node_output in outputs.values():
        for image in node_output.get("images", []) or []:
            images.append(image)

    return images


def remove_comfy_output(image_info):
    filename = image_info["filename"]
    subfolder = image_info.get("subfolder") or ""

    path = COMFY_DIR / "output" / subfolder / filename

    try:
        path.unlink()
    except FileNotFoundError:
        pass


def run_job(args):
    job_id = str(uuid.uuid4())[:12]

    family, config, workflow_path, use_reference = select_workflow(
        args.render_family,
        reference_mode=args.reference_mode,
        has_reference=bool(args.reference_image),
    )

    workflow = json.loads(workflow_path.read_text())

    filename_prefix = f"crestfall_{family.lower()}_{job_id}"

    reference_filename = None

    try:
        if use_reference:
            reference_filename = copy_reference_image(args.reference_image, job_id)
            patch_reference_image(
                workflow,
                config["reference_image_node"],
                reference_filename,
            )

        patch_text_nodes(workflow, config["positive_prompt_nodes"], args.prompt)
        patch_text_nodes(workflow, config["negative_prompt_nodes"], args.negative_prompt)

        patch_latent_node(
            workflow,
            config.get("latent_node"),
            args.width,
            args.height,
            args.batch_size,
        )

        used_seeds = patch_sampler_nodes(workflow, config["sampler_nodes"], args.seed)
        patch_save_node(workflow, config["save_node"], filename_prefix)

        print("Submitting Comfy job:")
        print(json.dumps({
            "job_id": job_id,
            "render_family": family,
            "workflow": str(workflow_path),
            "use_reference": use_reference,
            "reference_filename": reference_filename,
            "filename_prefix": filename_prefix,
            "seeds": used_seeds,
            "width": args.width,
            "height": args.height,
            "batch_size": args.batch_size,
        }, indent=2))

        prompt_id = submit_prompt(workflow)
        print(f"prompt_id={prompt_id}")

        history_entry = wait_for_prompt(prompt_id)
        images = collect_images(history_entry)

        if not images:
            raise RuntimeError("Comfy completed but returned no images.")

        output_dir = TEST_OUTPUT_DIR / job_id
        saved_files = []

        for image_info in images:
            saved = download_output_image(image_info, output_dir)
            saved_files.append(str(saved))

            if args.cleanup_comfy_output:
                remove_comfy_output(image_info)

        return {
            "ok": True,
            "job_id": job_id,
            "prompt_id": prompt_id,
            "render_family": family,
            "use_reference": use_reference,
            "saved_files": saved_files,
        }

    finally:
        if reference_filename and args.cleanup_reference_input:
            ref_path = COMFY_DIR / "input" / reference_filename
            try:
                ref_path.unlink()
            except FileNotFoundError:
                pass


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("--render-family", required=True)
    parser.add_argument("--reference-mode", default="auto", choices=["auto", "off"])
    parser.add_argument("--reference-image", default=None)

    parser.add_argument("--prompt", required=True)
    parser.add_argument("--negative-prompt", default="worst quality, low quality, blurry, bad anatomy, bad hands, text, watermark, logo")

    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=768)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--seed", type=int, default=None)

    parser.add_argument("--cleanup-comfy-output", action="store_true")
    parser.add_argument("--cleanup-reference-input", action="store_true")

    args = parser.parse_args()

    result = run_job(args)

    print("RESULT:")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

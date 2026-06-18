import os
from pathlib import Path

ASSETS_ROOT = Path(
    os.environ.get(
        "CRESTFALL_ASSETS",
        "/workspace/crestfall-comfy-service-assets",
    )
)

WORKFLOWS = {
    "ANIME_ANIME": {
        "base_workflow": "workflows/base/no_reference/crestfall_ANIME_ANIME.json",
        "reference_workflow": "workflows/base/reference/crestfall_ANIME_ANIME_REFERENCE.json",
        "reference_enabled": True,
        "positive_prompt_nodes": ["12", "14"],
        "negative_prompt_nodes": ["1", "6"],
        "latent_node": "2",
        "sampler_nodes": ["5", "8"],
        "save_node": "10",
        "reference_image_node": "20",
    },
    "FANTASY": {
        "base_workflow": "workflows/base/no_reference/crestfall_FANTASY.json",
        "reference_workflow": None,
        "reference_enabled": False,
        "positive_prompt_nodes": ["3"],
        "negative_prompt_nodes": ["4"],
        "latent_node": "5",
        "sampler_nodes": ["6"],
        "save_node": "8",
        "reference_image_node": None,
    },
    "FANTASY_REALISTIC": {
        "base_workflow": "workflows/base/no_reference/crestfall_FANTASY_REALISTIC.json",
        "reference_workflow": "workflows/base/reference/crestfall_FANTASY_REALISTIC_REFERENCE.json",
        "reference_enabled": True,
        "positive_prompt_nodes": ["3", "13"],
        "negative_prompt_nodes": ["4", "14"],
        "latent_node": "5",
        "sampler_nodes": ["6", "21"],
        "save_node": "8",
        "reference_image_node": "26",
    },
    "REALISTIC_FANTASY": {
        "base_workflow": "workflows/base/no_reference/crestfall_REALISTIC_FANTASY.json",
        "reference_workflow": "workflows/base/reference/crestfall_REALISTIC_FANTASY_REFERENCE.json",
        "reference_enabled": True,
        "positive_prompt_nodes": ["15", "14"],
        "negative_prompt_nodes": ["1", "6"],
        "latent_node": "2",
        "sampler_nodes": ["5", "8"],
        "save_node": "12",
        "reference_image_node": "17",
    },
    "REALISTIC": {
        "base_workflow": "workflows/base/no_reference/crestfall_REALISTIC.json",
        "reference_workflow": "workflows/base/reference/crestfall_REALISTIC_REFERENCE.json",
        "reference_enabled": True,
        "positive_prompt_nodes": ["4"],
        "negative_prompt_nodes": ["2"],
        "latent_node": "1",
        "sampler_nodes": ["6"],
        "save_node": "3",
        "reference_image_node": "8",
    },
}


def normalize_render_family(value):
    normalized = str(value or "").strip().upper()

    if normalized not in WORKFLOWS:
        raise ValueError(f"Unsupported render family: {value}")

    return normalized


def select_workflow(render_family, reference_mode="auto", has_reference=False):
    family = normalize_render_family(render_family)
    config = WORKFLOWS[family]

    wants_reference = str(reference_mode or "auto").strip().lower() != "off"

    use_reference = bool(
        wants_reference
        and has_reference
        and config.get("reference_enabled")
        and config.get("reference_workflow")
    )

    relative_path = (
        config["reference_workflow"]
        if use_reference
        else config["base_workflow"]
    )

    workflow_path = ASSETS_ROOT / relative_path

    if not workflow_path.exists():
        raise FileNotFoundError(f"Workflow not found: {workflow_path}")

    if workflow_path.stat().st_size <= 0:
        raise ValueError(f"Workflow file is empty: {workflow_path}")

    return family, config, workflow_path, use_reference

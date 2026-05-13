from __future__ import annotations

import argparse
import json
from pathlib import Path

from huggingface_hub import snapshot_download


ROOT = Path(__file__).resolve().parents[1]
MODELS_DIR = ROOT / "models"

TARGETS = [
    {
        "repo_id": "TencentARC/Pixal3D",
        "local_name": "Pixal3D",
        "allow_patterns": ["pipeline.json", "ckpts/*", "README.md", "LICENSE"],
        "required": True,
    },
    {
        "repo_id": "camenduru/dinov3-vitl16-pretrain-lvd1689m",
        "local_name": "dinov3-vitl16-pretrain-lvd1689m",
        "allow_patterns": None,
        "required": True,
    },
    {
        "repo_id": "Ruicheng/moge-2-vitl",
        "local_name": "moge-2-vitl",
        "allow_patterns": None,
        "required": True,
    },
    {
        "repo_id": "ZhengPeng7/BiRefNet",
        "local_name": "BiRefNet",
        "allow_patterns": None,
        "required": True,
    },
]


def has_transformers_checkpoint(model_dir: Path) -> bool:
    if not model_dir.exists():
        return False
    has_config = (model_dir / "config.json").exists()
    has_weights = any(model_dir.glob("*.safetensors")) or (model_dir / "pytorch_model.bin").exists()
    return has_config and has_weights


def local_model_reference(model_dir: Path) -> str:
    model_dir = model_dir.resolve()
    try:
        return model_dir.relative_to(ROOT).as_posix()
    except ValueError:
        return str(model_dir)


def patch_pipeline_json(models_dir: Path, prefer_rmbg2: bool = True) -> None:
    pipeline_path = models_dir / "Pixal3D" / "pipeline.json"
    if not pipeline_path.exists():
        return

    data = json.loads(pipeline_path.read_text(encoding="utf-8"))
    args = data.setdefault("args", {})

    rmbg2_dir = models_dir / "RMBG-2.0"
    birefnet_dir = models_dir / "BiRefNet"
    rembg_dir = rmbg2_dir if prefer_rmbg2 and has_transformers_checkpoint(rmbg2_dir) else birefnet_dir
    if rembg_dir.exists():
        args.setdefault("rembg_model", {}).setdefault("args", {})["model_name"] = local_model_reference(rembg_dir)

    dino_dir = models_dir / "dinov3-vitl16-pretrain-lvd1689m"
    if dino_dir.exists():
        args.setdefault("image_cond_model", {}).setdefault("args", {})["model_name"] = local_model_reference(dino_dir)

    pipeline_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print(f"Patched local pipeline.json: {pipeline_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Download local Pixal3D model files.")
    parser.add_argument("--models-dir", default=str(MODELS_DIR))
    parser.add_argument("--skip-existing", action="store_true")
    parser.add_argument("--core-only", action="store_true", help="Download only TencentARC/Pixal3D weights.")
    parser.add_argument("--no-prefer-rmbg2", action="store_true", help="Do not switch pipeline.json to models/RMBG-2.0 even if it exists.")
    args = parser.parse_args()

    models_dir = Path(args.models_dir).resolve()
    models_dir.mkdir(parents=True, exist_ok=True)

    targets = TARGETS[:1] if args.core_only else TARGETS
    for target in targets:
        local_dir = models_dir / target["local_name"]
        if args.skip_existing and local_dir.exists() and any(local_dir.iterdir()):
            print(f"Skipping existing {target['repo_id']} -> {local_dir}")
            continue

        print(f"Downloading {target['repo_id']} -> {local_dir}")
        try:
            snapshot_download(
                repo_id=target["repo_id"],
                local_dir=str(local_dir),
                local_dir_use_symlinks=False,
                allow_patterns=target["allow_patterns"],
                resume_download=True,
            )
        except Exception as exc:
            print(f"Failed to download {target['repo_id']}: {exc}")
            if target["required"]:
                raise

    patch_pipeline_json(models_dir, prefer_rmbg2=not args.no_prefer_rmbg2)
    print("Model download step finished.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

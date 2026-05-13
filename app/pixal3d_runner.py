from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image


IMAGE_COND_CONFIGS = {
    "ss": {
        "model_name": "camenduru/dinov3-vitl16-pretrain-lvd1689m",
        "image_size": 512,
        "grid_resolution": 16,
    },
    "shape_512": {
        "model_name": "camenduru/dinov3-vitl16-pretrain-lvd1689m",
        "image_size": 512,
        "grid_resolution": 32,
        "use_naf_upsample": True,
        "naf_target_size": 512,
    },
    "shape_1024": {
        "model_name": "camenduru/dinov3-vitl16-pretrain-lvd1689m",
        "image_size": 1024,
        "grid_resolution": 64,
        "use_naf_upsample": True,
        "naf_target_size": 512,
    },
    "tex_1024": {
        "model_name": "camenduru/dinov3-vitl16-pretrain-lvd1689m",
        "image_size": 1024,
        "grid_resolution": 64,
        "use_naf_upsample": True,
        "naf_target_size": 1024,
    },
}

MIN_SAFE_DECIMATION_TARGET = 30000
EXPORT_STATE_VERSION = 1
ROOT = Path(__file__).resolve().parents[1]


def models_dir() -> Path:
    return Path(os.environ.get("PIXAL3D_MODELS_DIR", str(ROOT / "models"))).resolve()


def local_model_reference(model_dir: Path) -> str:
    model_dir = model_dir.resolve()
    try:
        return model_dir.relative_to(ROOT).as_posix()
    except ValueError:
        return str(model_dir)


def _local_model(repo_id: str, local_name: str) -> str:
    candidate = models_dir() / local_name
    if candidate.exists() and any(candidate.iterdir()):
        return str(candidate)
    return repo_id


def _configure_model_paths() -> None:
    dino = _local_model("camenduru/dinov3-vitl16-pretrain-lvd1689m", "dinov3-vitl16-pretrain-lvd1689m")
    for config in IMAGE_COND_CONFIGS.values():
        config["model_name"] = dino


def build_image_cond_model(config: dict):
    from pixal3d.trainers.flow_matching.mixins.image_conditioned_proj import DinoV3ProjFeatureExtractor

    model = DinoV3ProjFeatureExtractor(**config)
    model.eval()
    return model


def load_moge_model(device: str = "cuda"):
    from moge.model.v2 import MoGeModel

    local_checkpoint = models_dir() / "moge-2-vitl" / "model.pt"
    model_name = str(local_checkpoint) if local_checkpoint.exists() else "Ruicheng/moge-2-vitl"
    moge_model = MoGeModel.from_pretrained(model_name).to(device)
    moge_model.eval()
    return moge_model


def has_transformers_checkpoint(model_dir: Path) -> bool:
    if not model_dir.exists():
        return False
    has_config = (model_dir / "config.json").exists()
    has_weights = any(model_dir.glob("*.safetensors")) or (model_dir / "pytorch_model.bin").exists()
    return has_config and has_weights


def refresh_local_pipeline_paths(model_path: str) -> str:
    candidate = Path(model_path)
    if not candidate.exists():
        return model_path

    pipeline_path = candidate / "pipeline.json"
    if not pipeline_path.exists():
        return model_path

    local_models = models_dir()
    data = json.loads(pipeline_path.read_text(encoding="utf-8"))
    args = data.setdefault("args", {})

    dino_dir = local_models / "dinov3-vitl16-pretrain-lvd1689m"
    if dino_dir.exists():
        args.setdefault("image_cond_model", {}).setdefault("args", {})["model_name"] = local_model_reference(dino_dir)

    rmbg2_dir = local_models / "RMBG-2.0"
    birefnet_dir = local_models / "BiRefNet"
    rembg_dir = rmbg2_dir if has_transformers_checkpoint(rmbg2_dir) else birefnet_dir
    if rembg_dir.exists():
        args.setdefault("rembg_model", {}).setdefault("args", {})["model_name"] = local_model_reference(rembg_dir)

    pipeline_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    return str(candidate)


def checkpoint_files(checkpoint_stem: Path) -> tuple[Path, Path]:
    return Path(f"{checkpoint_stem}.json"), Path(f"{checkpoint_stem}.safetensors")


def resolve_local_model_args(args: dict) -> dict:
    for section in ("image_cond_model", "rembg_model"):
        model_args = args.get(section, {}).get("args", {})
        model_name = model_args.get("model_name")
        if not isinstance(model_name, str):
            continue
        candidate = Path(model_name)
        if candidate.is_absolute():
            continue
        project_candidate = ROOT / candidate
        if project_candidate.exists():
            model_args["model_name"] = str(project_candidate)
    return args


def install_local_checkpoint_loader() -> None:
    from pixal3d import models
    from pixal3d.pipelines import base

    def from_pretrained(cls, path: str, config_file: str = "pipeline.json"):
        path_root = Path(path)
        local_config_file = path_root / config_file
        if not local_config_file.exists():
            return base.Pipeline._pixal3d_original_from_pretrained.__func__(cls, path, config_file)

        args = resolve_local_model_args(json.loads(local_config_file.read_text(encoding="utf-8"))["args"])
        loaded_models = {}
        for name, checkpoint in args["models"].items():
            if hasattr(cls, "model_names_to_load") and name not in cls.model_names_to_load:
                continue

            local_stem = path_root / checkpoint
            local_json, local_weights = checkpoint_files(local_stem)
            if local_json.exists() and local_weights.exists():
                try:
                    loaded_models[name] = models.from_pretrained(str(local_stem))
                except Exception as exc:
                    raise RuntimeError(
                        f"Failed to load local Pixal3D checkpoint '{name}' from {local_stem}."
                    ) from exc
            else:
                loaded_models[name] = models.from_pretrained(checkpoint)

        pipeline = cls(loaded_models)
        pipeline._pretrained_args = args
        return pipeline

    if not hasattr(base.Pipeline, "_pixal3d_original_from_pretrained"):
        base.Pipeline._pixal3d_original_from_pretrained = base.Pipeline.from_pretrained
        base.Pipeline.from_pretrained = classmethod(from_pretrained)


def exception_chain_text(exc: BaseException) -> str:
    parts = []
    current: BaseException | None = exc
    while current is not None:
        parts.append(f"{type(current).__name__}: {current}")
        current = current.__cause__ or current.__context__
    return "\n".join(parts).lower()


def set_attention_backend(backend: str) -> None:
    os.environ["ATTN_BACKEND"] = backend
    os.environ["SPARSE_ATTN_BACKEND"] = backend
    try:
        from pixal3d.modules.attention import config as attention_config
        from pixal3d.modules.sparse import config as sparse_config

        attention_config.set_backend(backend)
        sparse_config.set_attn_backend(backend)
    except Exception:
        pass


def compute_f_pixels(camera_angle_x: float, resolution: int) -> float:
    focal_length = 16.0 / torch.tan(torch.tensor(camera_angle_x / 2.0))
    f_pixels = focal_length * resolution / 32.0
    return float(f_pixels.item())


def distance_from_fov(camera_angle_x, grid_point, target_point, mesh_scale, image_resolution):
    rotation_matrix = torch.tensor([[1.0, 0.0, 0.0], [0.0, 0.0, -1.0], [0.0, 1.0, 0.0]])
    gp = grid_point.to(torch.float32) @ rotation_matrix.T
    gp = gp / mesh_scale / 2
    xw, yw = gp[0].item(), gp[1].item()
    xt = float(target_point[0].item())
    f_pixels = compute_f_pixels(camera_angle_x, image_resolution)
    x_ndc = xt - image_resolution / 2.0
    distance_x = f_pixels * xw / x_ndc - yw
    return {"distance_from_x": float(distance_x), "f_pixels": float(f_pixels)}


def get_camera_params_wild_moge(image_path, moge_model, device="cuda", mesh_scale=1.0, extend_pixel=0, image_resolution=512):
    pil_image = Image.open(image_path).convert("RGB")
    width, _height = pil_image.size
    image_np = np.array(pil_image).astype(np.float32) / 255.0
    image_tensor = torch.from_numpy(image_np).permute(2, 0, 1).to(device)
    with torch.no_grad():
        output = moge_model.infer(image_tensor)
    intrinsics = output["intrinsics"].squeeze().cpu().numpy()
    fx_normalized = intrinsics[0, 0]
    fx = fx_normalized * width
    camera_angle_x = 2 * math.atan(width / (2 * fx))

    grid_point = torch.tensor([-1.0, 0.0, 0.0])
    distance = distance_from_fov(
        camera_angle_x,
        grid_point,
        torch.tensor([0 - extend_pixel, image_resolution - 1 + extend_pixel]),
        mesh_scale,
        image_resolution,
    )["distance_from_x"]
    return {"camera_angle_x": camera_angle_x, "distance": distance, "mesh_scale": mesh_scale}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local Pixal3D runner")
    parser.add_argument("--pixal3d-dir", required=True)
    parser.add_argument("--image")
    parser.add_argument("--output", required=True)
    parser.add_argument("--model-path", default="TencentARC/Pixal3D")
    parser.add_argument("--state-output")
    parser.add_argument("--state-input")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--resolution", type=int, choices=[1024, 1536], default=1024)
    parser.add_argument("--ss-steps", type=int, default=12)
    parser.add_argument("--shape-steps", type=int, default=12)
    parser.add_argument("--tex-steps", type=int, default=12)
    parser.add_argument("--decimation-target", type=int, default=200000)
    parser.add_argument("--texture-size", type=int, default=2048)
    parser.add_argument("--max-num-tokens", type=int, default=49152)
    parser.add_argument("--attention-backend", choices=["flash_attn", "flash_attn_3", "xformers"], default="flash_attn_3")
    parser.add_argument("--low-vram", action="store_true")
    return parser.parse_args()


def safe_decimation_target(decimation_target: int) -> int:
    if decimation_target >= MIN_SAFE_DECIMATION_TARGET:
        return decimation_target
    print(
        "[Export] decimation-target "
        f"{decimation_target} is below the stable CuMesh UV unwrap range; "
        f"using {MIN_SAFE_DECIMATION_TARGET} instead."
    )
    return MIN_SAFE_DECIMATION_TARGET


def load_torch_file(path: Path):
    try:
        return torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        return torch.load(path, map_location="cpu")


def tensor_to_cpu(value):
    if isinstance(value, torch.Tensor):
        return value.detach().cpu()
    return value


def save_export_state(mesh, grid_size, attr_layout, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "version": EXPORT_STATE_VERSION,
            "mesh": {
                "vertices": tensor_to_cpu(mesh.vertices),
                "faces": tensor_to_cpu(mesh.faces),
                "attrs": tensor_to_cpu(mesh.attrs),
                "coords": tensor_to_cpu(mesh.coords),
            },
            "grid_size": tensor_to_cpu(grid_size),
            "attr_layout": attr_layout,
        },
        output_path,
    )
    print(f"[ExportState] Saved reusable export state to: {output_path}")


def to_cuda(value):
    if isinstance(value, torch.Tensor):
        return value.cuda()
    return value


def export_glb_from_state(state_path: Path, output_path: Path, decimation_target: int, texture_size: int, use_tqdm: bool = True) -> None:
    import o_voxel

    print(f"[ExportState] Loading reusable export state: {state_path}")
    state = load_torch_file(state_path)
    if state.get("version") != EXPORT_STATE_VERSION:
        raise RuntimeError(f"Unsupported export state version: {state.get('version')}")

    mesh = state["mesh"]
    print("[Export] Extracting GLB from saved mesh state")
    glb = o_voxel.postprocess.to_glb(
        vertices=to_cuda(mesh["vertices"]),
        faces=to_cuda(mesh["faces"]),
        attr_volume=to_cuda(mesh["attrs"]),
        coords=to_cuda(mesh["coords"]),
        attr_layout=state["attr_layout"],
        grid_size=to_cuda(state["grid_size"]),
        aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]],
        decimation_target=safe_decimation_target(decimation_target),
        texture_size=texture_size,
        remesh=True,
        remesh_band=1,
        remesh_project=0,
        use_tqdm=use_tqdm,
    )
    rotation = np.array(
        [
            [-1, 0, 0, 0],
            [0, 0, -1, 0],
            [0, -1, 0, 0],
            [0, 0, 0, 1],
        ],
        dtype=np.float64,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    glb.apply_transform(rotation)
    glb.export(output_path, extension_webp=True)
    print(f"[Done] GLB saved to: {output_path}")


def main() -> int:
    args = parse_args()
    pixal3d_dir = Path(args.pixal3d_dir).resolve()
    sys.path.insert(0, str(pixal3d_dir))
    model_path = refresh_local_pipeline_paths(args.model_path)

    os.environ["OPENCV_IO_ENABLE_OPENEXR"] = "1"
    os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"
    set_attention_backend(args.attention_backend)
    os.environ.setdefault("SPARSE_CONV_BACKEND", "flex_gemm")
    os.environ["FLEX_GEMM_AUTOTUNE_CACHE_PATH"] = str(pixal3d_dir / "autotune_cache.json")
    os.environ.setdefault("FLEX_GEMM_AUTOTUNER_VERBOSE", "1")

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is not available. Pixal3D requires an NVIDIA CUDA GPU.")

    if args.state_input:
        export_glb_from_state(
            Path(args.state_input).resolve(),
            Path(args.output).resolve(),
            args.decimation_target,
            args.texture_size,
        )
        return 0

    if not args.image:
        raise RuntimeError("--image is required unless --state-input is provided.")

    _configure_model_paths()

    from pixal3d.pipelines import Pixal3DImageTo3DPipeline
    import o_voxel
    install_local_checkpoint_loader()

    print(f"[Pipeline] Loading from {model_path}")
    try:
        pipeline = Pixal3DImageTo3DPipeline.from_pretrained(model_path)
    except Exception as exc:
        if args.attention_backend == "flash_attn_3" and "boolean value of tensor with no values is ambiguous" in exception_chain_text(exc):
            print("[Pipeline] flash_attn_3 failed during model initialization. Local checkpoint fallback is disabled; showing the real initialization error.")
        raise

    print("[ImageCond] Building DINOv3 projection models")
    pipeline.image_cond_model_ss = build_image_cond_model(IMAGE_COND_CONFIGS["ss"])
    pipeline.image_cond_model_shape_512 = build_image_cond_model(IMAGE_COND_CONFIGS["shape_512"])
    pipeline.image_cond_model_shape_1024 = build_image_cond_model(IMAGE_COND_CONFIGS["shape_1024"])
    pipeline.image_cond_model_tex_1024 = build_image_cond_model(IMAGE_COND_CONFIGS["tex_1024"])

    pipeline.low_vram = bool(args.low_vram)
    pipeline.cuda()
    if not pipeline.low_vram:
        pipeline.image_cond_model_ss.cuda()
        pipeline.image_cond_model_shape_512.cuda()
        pipeline.image_cond_model_shape_1024.cuda()
        pipeline.image_cond_model_tex_1024.cuda()

    print("[NAF] Pre-loading upsampler")
    for attr in ("image_cond_model_shape_512", "image_cond_model_shape_1024", "image_cond_model_tex_1024"):
        model = getattr(pipeline, attr, None)
        if model is not None and getattr(model, "use_naf_upsample", False):
            if pipeline.low_vram:
                model.cuda()
            model._load_naf()
            if pipeline.low_vram:
                model.cpu()

    print("[MoGe-2] Loading camera estimation model")
    moge_model = load_moge_model(device="cuda")

    print(f"[Inference] Processing image: {args.image}")
    image = Image.open(args.image)
    image_preprocessed = pipeline.preprocess_image(image)
    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = output_path.parent / f"_tmp_preprocessed_{int(time.time() * 1000)}.png"
    image_preprocessed.save(tmp_path)

    print("[Inference] Estimating camera parameters")
    camera_params = get_camera_params_wild_moge(tmp_path, moge_model, device="cuda")
    tmp_path.unlink(missing_ok=True)
    del moge_model
    torch.cuda.empty_cache()
    print("[MoGe-2] Released camera estimation model")
    print(f"[Inference] camera_angle_x={camera_params['camera_angle_x']:.4f}, distance={camera_params['distance']:.4f}")

    torch.manual_seed(args.seed)
    ss_sampler_override = {
        "steps": args.ss_steps,
        "guidance_strength": 7.5,
        "guidance_rescale": 0.7,
        "rescale_t": 5.0,
    }
    shape_sampler_override = {
        "steps": args.shape_steps,
        "guidance_strength": 7.5,
        "guidance_rescale": 0.5,
        "rescale_t": 3.0,
    }
    tex_sampler_override = {
        "steps": args.tex_steps,
        "guidance_strength": 1.0,
        "guidance_rescale": 0.0,
        "rescale_t": 3.0,
    }

    pipeline_type = f"{args.resolution}_cascade"
    print(f"[Inference] Running 3D generation pipeline: {pipeline_type}")
    mesh_list, _latents = pipeline.run(
        image_preprocessed,
        camera_params=camera_params,
        seed=args.seed,
        sparse_structure_sampler_params=ss_sampler_override,
        shape_slat_sampler_params=shape_sampler_override,
        tex_slat_sampler_params=tex_sampler_override,
        preprocess_image=False,
        return_latent=True,
        pipeline_type=pipeline_type,
        max_num_tokens=args.max_num_tokens,
    )
    mesh = mesh_list[0]

    if args.state_output:
        save_export_state(mesh, _latents[2], pipeline.pbr_attr_layout, Path(args.state_output).resolve())

    print("[Inference] Extracting GLB")
    glb = o_voxel.postprocess.to_glb(
        vertices=mesh.vertices,
        faces=mesh.faces,
        attr_volume=mesh.attrs,
        coords=mesh.coords,
        attr_layout=pipeline.pbr_attr_layout,
        grid_size=_latents[2],
        aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]],
        decimation_target=safe_decimation_target(args.decimation_target),
        texture_size=args.texture_size,
        remesh=True,
        remesh_band=1,
        remesh_project=0,
        use_tqdm=True,
    )
    rotation = np.array(
        [
            [-1, 0, 0, 0],
            [0, 0, -1, 0],
            [0, -1, 0, 0],
            [0, 0, 0, 1],
        ],
        dtype=np.float64,
    )
    glb.apply_transform(rotation)
    glb.export(output_path, extension_webp=True)
    print(f"[Done] GLB saved to: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

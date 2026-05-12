from __future__ import annotations

import argparse
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


def _local_model(repo_id: str, local_name: str) -> str:
    models_dir = Path(os.environ.get("PIXAL3D_MODELS_DIR", "models")).resolve()
    candidate = models_dir / local_name
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

    models_dir = Path(os.environ.get("PIXAL3D_MODELS_DIR", "models")).resolve()
    local_checkpoint = models_dir / "moge-2-vitl" / "model.pt"
    model_name = str(local_checkpoint) if local_checkpoint.exists() else "Ruicheng/moge-2-vitl"
    moge_model = MoGeModel.from_pretrained(model_name).to(device)
    moge_model.eval()
    return moge_model


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
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model-path", default="TencentARC/Pixal3D")
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


def main() -> int:
    args = parse_args()
    pixal3d_dir = Path(args.pixal3d_dir).resolve()
    sys.path.insert(0, str(pixal3d_dir))

    os.environ["OPENCV_IO_ENABLE_OPENEXR"] = "1"
    os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"
    os.environ["ATTN_BACKEND"] = args.attention_backend
    os.environ["SPARSE_ATTN_BACKEND"] = args.attention_backend
    os.environ.setdefault("SPARSE_CONV_BACKEND", "flex_gemm")
    os.environ["FLEX_GEMM_AUTOTUNE_CACHE_PATH"] = str(pixal3d_dir / "autotune_cache.json")
    os.environ.setdefault("FLEX_GEMM_AUTOTUNER_VERBOSE", "1")

    _configure_model_paths()

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is not available. Pixal3D requires an NVIDIA CUDA GPU.")

    from pixal3d.pipelines import Pixal3DImageTo3DPipeline
    import o_voxel

    print(f"[Pipeline] Loading from {args.model_path}")
    pipeline = Pixal3DImageTo3DPipeline.from_pretrained(args.model_path)

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

    print("[Inference] Extracting GLB")
    glb = o_voxel.postprocess.to_glb(
        vertices=mesh.vertices,
        faces=mesh.faces,
        attr_volume=mesh.attrs,
        coords=mesh.coords,
        attr_layout=pipeline.pbr_attr_layout,
        grid_size=_latents[2],
        aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]],
        decimation_target=args.decimation_target,
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

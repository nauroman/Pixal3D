from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles


ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = ROOT / "static"
UPLOADS_DIR = ROOT / "uploads"
OUTPUTS_DIR = ROOT / "outputs"
MODELS_DIR = ROOT / "models"
PIXAL3D_DIR = ROOT / "vendor" / "Pixal3D"
TRELLIS2_DIR = ROOT / "vendor" / "TRELLIS.2"
ENGINE_DIR = ROOT / "engine"
THREE_DIR = ROOT / "node_modules" / "three"
MIN_SAFE_DECIMATION_TARGET = 30000
TEXTURE_SIZE_OPTIONS = {1024, 2048, 4096}

for directory in (UPLOADS_DIR, OUTPUTS_DIR, MODELS_DIR, ENGINE_DIR):
    directory.mkdir(parents=True, exist_ok=True)


MODEL_FILES = [
    ("pipeline.json", 4068),
    ("ckpts/shape_dec_next_dc_f16c32_fp16.json", 678),
    ("ckpts/shape_dec_next_dc_f16c32_fp16.safetensors", 948490494),
    ("ckpts/slat_flow_img2shape_dit_1_3B_1024_bf16.json", 535),
    ("ckpts/slat_flow_img2shape_dit_1_3B_1024_bf16.safetensors", 5546764048),
    ("ckpts/slat_flow_img2shape_dit_1_3B_512_bf16.json", 535),
    ("ckpts/slat_flow_img2shape_dit_1_3B_512_bf16.safetensors", 5546764048),
    ("ckpts/slat_flow_imgshape2tex_dit_1_3B_1024_bf16.json", 535),
    ("ckpts/slat_flow_imgshape2tex_dit_1_3B_1024_bf16.safetensors", 5546960656),
    ("ckpts/ss_dec_conv3d_16l8_fp16.json", 245),
    ("ckpts/ss_dec_conv3d_16l8_fp16.safetensors", 147591972),
    ("ckpts/ss_flow_img_dit_1_3B_64_bf16.json", 503),
    ("ckpts/ss_flow_img_dit_1_3B_64_bf16.safetensors", 5359822584),
    ("ckpts/tex_dec_next_dc_f16c32_fp16.json", 705),
    ("ckpts/tex_dec_next_dc_f16c32_fp16.safetensors", 948458812),
]


jobs: dict[str, dict[str, Any]] = {}
jobs_lock = threading.Lock()


app = FastAPI(title="Pixal3D Local UI", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:7868", "http://localhost:7868"],
    allow_methods=["*"],
    allow_headers=["*"],
)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
app.mount("/outputs", StaticFiles(directory=OUTPUTS_DIR), name="outputs")
app.mount("/uploads", StaticFiles(directory=UPLOADS_DIR), name="uploads")
app.mount("/three", StaticFiles(directory=THREE_DIR, check_dir=False), name="three")


def _run(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            cmd,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
            encoding="utf-8",
            errors="replace",
        )
        return completed.returncode, (completed.stdout + completed.stderr).strip()
    except Exception as exc:
        return 1, str(exc)


def _human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{size} B"


def _pixal3d_model_dir() -> Path:
    local = MODELS_DIR / "Pixal3D"
    return local if (local / "pipeline.json").exists() else MODELS_DIR / "TencentARC" / "Pixal3D"


def _model_status() -> dict[str, Any]:
    model_dir = _pixal3d_model_dir()
    files = []
    present_count = 0
    present_size = 0
    expected_size = 0
    for relative, expected in MODEL_FILES:
        path = model_dir / relative
        exists = path.exists()
        actual = path.stat().st_size if exists else 0
        present_count += 1 if exists else 0
        present_size += actual
        expected_size += expected
        files.append(
            {
                "path": relative,
                "exists": exists,
                "size": actual,
                "expected": expected,
                "sizeText": _human_size(actual),
                "expectedText": _human_size(expected),
            }
        )
    return {
        "dir": str(model_dir),
        "ready": present_count == len(MODEL_FILES),
        "present": present_count,
        "total": len(MODEL_FILES),
        "size": present_size,
        "expectedSize": expected_size,
        "sizeText": _human_size(present_size),
        "expectedSizeText": _human_size(expected_size),
        "files": files,
    }


def _gpu_status() -> dict[str, Any]:
    if shutil.which("nvidia-smi") is None:
        return {"available": False, "message": "nvidia-smi not found"}
    code, output = _run(
        [
            "nvidia-smi",
            "--query-gpu=name,memory.total,driver_version",
            "--format=csv,noheader,nounits",
        ],
        timeout=10,
    )
    if code != 0:
        return {"available": False, "message": output}
    first = output.splitlines()[0] if output else ""
    parts = [part.strip() for part in first.split(",")]
    return {
        "available": True,
        "name": parts[0] if len(parts) > 0 else first,
        "memoryMB": int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None,
        "driver": parts[2] if len(parts) > 2 else None,
        "raw": output,
    }


def _wsl_status() -> dict[str, Any]:
    if platform.system() != "Windows":
        return {"needed": False, "available": True, "message": "Running outside Windows"}
    code, output = _run(["wsl", "--status"], timeout=5)
    installed = code == 0 and "not installed" not in output.lower()
    return {"needed": True, "available": installed, "message": output}


def _engine_python() -> list[str]:
    env_value = os.environ.get("PIXAL3D_PYTHON")
    if env_value:
        return [env_value]

    path_file = ENGINE_DIR / "python_path.txt"
    if path_file.exists():
        configured = path_file.read_text(encoding="utf-8").strip()
        if configured:
            return [configured]

    local_venv = ROOT / ".pixal3d-venv" / ("Scripts/python.exe" if platform.system() == "Windows" else "bin/python")
    if local_venv.exists():
        return [str(local_venv)]

    return [sys.executable]


def _engine_status() -> dict[str, Any]:
    python_cmd = _engine_python()
    code, output = _run(python_cmd + ["--version"], timeout=10)
    probe_code = r"""
import importlib.util
import json

mods = ["torch", "o_voxel", "moge", "nvdiffrast", "flex_gemm", "cumesh", "natten"]
data = {module: importlib.util.find_spec(module) is not None for module in mods}
data["attention"] = any(importlib.util.find_spec(module) is not None for module in ["flash_attn", "flash_attn_interface", "xformers"])
data["nattenCuda"] = False
try:
    import torch
    if torch.cuda.is_available() and data["natten"]:
        from natten.functional import na2d

        q = torch.randn(1, 8, 8, 2, 16, device="cuda", dtype=torch.float16)
        na2d(q, q, q, kernel_size=3, dilation=1)
        torch.cuda.synchronize()
        data["nattenCuda"] = True
except Exception as exc:
    data["nattenCudaError"] = str(exc)
print(json.dumps(data))
"""
    dep_code, dep_output = _run(python_cmd + ["-c", probe_code], timeout=20)
    dependencies: dict[str, bool] = {}
    if dep_code == 0:
        try:
            dependencies = json.loads(dep_output.splitlines()[-1])
        except Exception:
            dependencies = {}
    deps_ok = bool(dependencies) and all(
        value is True for key, value in dependencies.items() if not key.endswith("Error")
    ) and not any(key.endswith("Error") for key in dependencies)
    return {
        "python": python_cmd[0],
        "pythonOk": code == 0,
        "pythonVersion": output,
        "runner": str(ROOT / "app" / "pixal3d_runner.py"),
        "runnerExists": (ROOT / "app" / "pixal3d_runner.py").exists(),
        "dependencies": dependencies,
        "dependenciesOk": deps_ok,
        "ready": code == 0 and (ROOT / "app" / "pixal3d_runner.py").exists() and deps_ok,
    }


def _append_log(job: dict[str, Any], line: str) -> None:
    cleaned = line.rstrip()
    if not cleaned:
        return
    job["log"].append(cleaned)
    if len(job["log"]) > 500:
        job["log"] = job["log"][-500:]
    with open(job["logPath"], "a", encoding="utf-8", errors="replace") as handle:
        handle.write(cleaned + "\n")


def _set_job(job_id: str, **values: Any) -> None:
    with jobs_lock:
        if job_id in jobs:
            jobs[job_id].update(values)


def _normalize_decimation(decimation: int) -> int:
    return max(int(decimation), MIN_SAFE_DECIMATION_TARGET)


def _validate_texture_size(texture_size: int) -> int:
    texture_size = int(texture_size)
    if texture_size not in TEXTURE_SIZE_OPTIONS:
        raise HTTPException(status_code=400, detail="textureSize must be 1024, 2048, or 4096")
    return texture_size


def _export_filename(decimation: int, texture_size: int) -> str:
    return f"model_d{decimation}_t{texture_size}.glb"


def _output_url(job_id: str, output_path: Path) -> str:
    return f"/outputs/{job_id}/{output_path.name}"


def _run_generation(job_id: str) -> None:
    with jobs_lock:
        job = jobs[job_id]

    _set_job(job_id, status="running", stage="Starting Pixal3D backend", startedAt=time.time())

    output_path = Path(job["outputPath"])
    input_path = Path(job["inputPath"])
    state_path = Path(job["statePath"])
    model_dir = _pixal3d_model_dir()
    runner = ROOT / "app" / "pixal3d_runner.py"

    if not PIXAL3D_DIR.exists():
        _set_job(job_id, status="failed", stage="Pixal3D repository missing")
        _append_log(job, f"Missing repo: {PIXAL3D_DIR}")
        return

    cmd = _engine_python() + [
        str(runner),
        "--pixal3d-dir",
        str(PIXAL3D_DIR),
        "--image",
        str(input_path),
        "--output",
        str(output_path),
        "--state-output",
        str(state_path),
        "--model-path",
        str(model_dir if (model_dir / "pipeline.json").exists() else "TencentARC/Pixal3D"),
        "--seed",
        str(job["params"]["seed"]),
        "--resolution",
        str(job["params"]["resolution"]),
        "--ss-steps",
        str(job["params"]["ssSteps"]),
        "--shape-steps",
        str(job["params"]["shapeSteps"]),
        "--tex-steps",
        str(job["params"]["texSteps"]),
        "--decimation-target",
        str(job["params"]["decimation"]),
        "--texture-size",
        str(job["params"]["textureSize"]),
        "--attention-backend",
        str(job["params"]["attentionBackend"]),
        "--max-num-tokens",
        str(job["params"]["maxTokens"]),
    ]

    if job["params"]["lowVram"]:
        cmd.append("--low-vram")

    _append_log(job, "Command: " + " ".join(f'"{part}"' if " " in part else part for part in cmd))
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["PIXAL3D_MODELS_DIR"] = str(MODELS_DIR)

    try:
        process = subprocess.Popen(
            cmd,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
        )
        assert process.stdout is not None
        for line in process.stdout:
            _append_log(job, line)
            lower = line.lower()
            if "loading" in lower:
                _set_job(job_id, stage="Loading models")
            elif "camera" in lower:
                _set_job(job_id, stage="Estimating camera")
            elif "running 3d" in lower or "generation" in lower:
                _set_job(job_id, stage="Generating 3D asset")
            elif "extracting" in lower or "to_glb" in lower or "glb" in lower:
                _set_job(job_id, stage="Exporting GLB")
        exit_code = process.wait()
    except Exception as exc:
        _append_log(job, f"Backend launch failed: {exc}")
        _set_job(job_id, status="failed", stage="Backend launch failed", finishedAt=time.time())
        return

    if exit_code == 0 and output_path.exists():
        _set_job(
            job_id,
            status="complete",
            stage="Complete",
            finishedAt=time.time(),
            resultUrl=_output_url(job_id, output_path),
        )
    else:
        _append_log(job, f"Pixal3D exited with code {exit_code}")
        _set_job(job_id, status="failed", stage=f"Failed with code {exit_code}", finishedAt=time.time())


def _run_export(job_id: str, decimation: int, texture_size: int, output_path: str) -> None:
    with jobs_lock:
        job = jobs.get(job_id)
    if job is None:
        return

    output_file = Path(output_path)
    state_path = Path(job["statePath"])
    runner = ROOT / "app" / "pixal3d_runner.py"

    if not PIXAL3D_DIR.exists():
        _set_job(job_id, exportStatus="failed", exportStage="Pixal3D repository missing", exportFinishedAt=time.time())
        _append_log(job, f"Missing repo: {PIXAL3D_DIR}")
        return
    if not state_path.exists():
        _set_job(job_id, exportStatus="failed", exportStage="Export state missing", exportFinishedAt=time.time())
        _append_log(job, f"Missing export state: {state_path}")
        return

    cmd = _engine_python() + [
        str(runner),
        "--pixal3d-dir",
        str(PIXAL3D_DIR),
        "--state-input",
        str(state_path),
        "--output",
        str(output_file),
        "--decimation-target",
        str(decimation),
        "--texture-size",
        str(texture_size),
    ]

    _append_log(job, "Export command: " + " ".join(f'"{part}"' if " " in part else part for part in cmd))
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["PIXAL3D_MODELS_DIR"] = str(MODELS_DIR)

    try:
        process = subprocess.Popen(
            cmd,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
        )
        assert process.stdout is not None
        for line in process.stdout:
            _append_log(job, line)
            lower = line.lower()
            if "loading reusable export state" in lower:
                _set_job(job_id, exportStage="Loading export state")
            elif "extracting" in lower or "to_glb" in lower:
                _set_job(job_id, exportStage="Rebuilding GLB")
            elif "sampling attributes" in lower:
                _set_job(job_id, exportStage="Baking texture")
            elif "finalizing" in lower or "glb saved" in lower:
                _set_job(job_id, exportStage="Finalizing export")
        exit_code = process.wait()
    except Exception as exc:
        _append_log(job, f"Export launch failed: {exc}")
        _set_job(
            job_id,
            exportStatus="failed",
            exportStage="Export launch failed",
            exportFinishedAt=time.time(),
            exportError=str(exc),
        )
        return

    if exit_code == 0 and output_file.exists():
        with jobs_lock:
            job = jobs.get(job_id)
            if job is not None:
                job["params"]["decimation"] = decimation
                job["params"]["textureSize"] = texture_size
                job["outputPath"] = str(output_file)
                job["resultUrl"] = _output_url(job_id, output_file)
                job["exportStatus"] = "idle"
                job["exportStage"] = "Export complete"
                job["exportFinishedAt"] = time.time()
                job["exportError"] = None
                job["pendingExport"] = None
    else:
        output_file.unlink(missing_ok=True)
        _append_log(job, f"Export exited with code {exit_code}")
        _set_job(
            job_id,
            exportStatus="failed",
            exportStage=f"Export failed with code {exit_code}",
            exportFinishedAt=time.time(),
            exportError=f"exit code {exit_code}",
            pendingExport=None,
        )


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/status")
def status() -> dict[str, Any]:
    return {
        "root": str(ROOT),
        "os": platform.platform(),
        "python": sys.version,
        "pixal3dRepo": {"exists": PIXAL3D_DIR.exists(), "path": str(PIXAL3D_DIR)},
        "trellis2Repo": {"exists": TRELLIS2_DIR.exists(), "path": str(TRELLIS2_DIR)},
        "nodeModules": {"three": THREE_DIR.exists(), "path": str(THREE_DIR)},
        "gpu": _gpu_status(),
        "wsl": _wsl_status(),
        "model": _model_status(),
        "engine": _engine_status(),
    }


@app.post("/api/jobs")
async def create_job(
    image: UploadFile = File(...),
    seed: int = Form(42),
    resolution: int = Form(1024),
    ssSteps: int = Form(12),
    shapeSteps: int = Form(12),
    texSteps: int = Form(12),
    decimation: int = Form(200000),
    textureSize: int = Form(2048),
    maxTokens: int = Form(49152),
    attentionBackend: str = Form("flash_attn_3"),
    lowVram: bool = Form(True),
) -> dict[str, Any]:
    if resolution not in (1024, 1536):
        raise HTTPException(status_code=400, detail="resolution must be 1024 or 1536")
    if attentionBackend not in ("flash_attn", "flash_attn_3", "xformers"):
        raise HTTPException(status_code=400, detail="unsupported attention backend")
    decimation = _normalize_decimation(decimation)
    textureSize = _validate_texture_size(textureSize)

    job_id = uuid.uuid4().hex
    job_upload_dir = UPLOADS_DIR / job_id
    job_output_dir = OUTPUTS_DIR / job_id
    job_upload_dir.mkdir(parents=True, exist_ok=True)
    job_output_dir.mkdir(parents=True, exist_ok=True)

    suffix = Path(image.filename or "input.png").suffix.lower()
    if not re.fullmatch(r"\.(png|jpe?g|webp|bmp)", suffix):
        suffix = ".png"
    input_path = job_upload_dir / f"input{suffix}"
    content = await image.read()
    input_path.write_bytes(content)

    job = {
        "id": job_id,
        "status": "queued",
        "stage": "Queued",
        "createdAt": time.time(),
        "startedAt": None,
        "finishedAt": None,
        "inputPath": str(input_path),
        "inputUrl": f"/uploads/{job_id}/{input_path.name}",
        "outputPath": str(job_output_dir / _export_filename(decimation, textureSize)),
        "statePath": str(job_output_dir / "export_state.pt"),
        "resultUrl": None,
        "exportStatus": "idle",
        "exportStage": "",
        "exportStartedAt": None,
        "exportFinishedAt": None,
        "exportError": None,
        "pendingExport": None,
        "logPath": str(job_output_dir / "run.log"),
        "log": [],
        "params": {
            "seed": seed,
            "resolution": resolution,
            "ssSteps": ssSteps,
            "shapeSteps": shapeSteps,
            "texSteps": texSteps,
            "decimation": decimation,
            "textureSize": textureSize,
            "maxTokens": maxTokens,
            "attentionBackend": attentionBackend,
            "lowVram": lowVram,
        },
    }
    Path(job["logPath"]).write_text("", encoding="utf-8")
    with jobs_lock:
        jobs[job_id] = job

    worker = threading.Thread(target=_run_generation, args=(job_id,), daemon=True)
    worker.start()
    return _public_job(job)


@app.post("/api/jobs/{job_id}/exports")
async def create_export(
    job_id: str,
    decimation: int = Form(200000),
    textureSize: int = Form(2048),
) -> dict[str, Any]:
    decimation = _normalize_decimation(decimation)
    textureSize = _validate_texture_size(textureSize)

    with jobs_lock:
        job = jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="job not found")
        if job["status"] != "complete":
            raise HTTPException(status_code=409, detail="model generation is not complete")
        if job.get("exportStatus") == "exporting":
            raise HTTPException(status_code=409, detail="an export is already running")

        state_path_value = job.get("statePath")
        if not state_path_value:
            raise HTTPException(status_code=409, detail="reusable export state is missing")
        state_path = Path(state_path_value)
        if not state_path.exists():
            raise HTTPException(status_code=409, detail="reusable export state is missing")

        output_path = Path(job["outputPath"]).parent / _export_filename(decimation, textureSize)
        if output_path.exists():
            job["params"]["decimation"] = decimation
            job["params"]["textureSize"] = textureSize
            job["outputPath"] = str(output_path)
            job["resultUrl"] = _output_url(job_id, output_path)
            job["exportStatus"] = "idle"
            job["exportStage"] = "Export ready"
            job["exportError"] = None
            response = _public_job(job)
            cached = True
        else:
            job["exportStatus"] = "exporting"
            job["exportStage"] = "Starting export"
            job["exportStartedAt"] = time.time()
            job["exportFinishedAt"] = None
            job["exportError"] = None
            job["pendingExport"] = {
                "decimation": decimation,
                "textureSize": textureSize,
                "outputPath": str(output_path),
            }
            response = _public_job(job)
            cached = False

    if cached:
        _append_log(job, f"Reused cached export: {output_path.name}")
    else:
        worker = threading.Thread(
            target=_run_export,
            args=(job_id, decimation, textureSize, str(output_path)),
            daemon=True,
        )
        worker.start()

    return response


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str) -> dict[str, Any]:
    with jobs_lock:
        job = jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="job not found")
        return _public_job(job)


def _public_job(job: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": job["id"],
        "status": job["status"],
        "stage": job["stage"],
        "createdAt": job["createdAt"],
        "startedAt": job["startedAt"],
        "finishedAt": job["finishedAt"],
        "inputUrl": job["inputUrl"],
        "resultUrl": job["resultUrl"],
        "hasExportState": bool(job.get("statePath")) and Path(job["statePath"]).exists(),
        "exportStatus": job.get("exportStatus", "idle"),
        "exportStage": job.get("exportStage", ""),
        "exportStartedAt": job.get("exportStartedAt"),
        "exportFinishedAt": job.get("exportFinishedAt"),
        "exportError": job.get("exportError"),
        "pendingExport": job.get("pendingExport"),
        "params": job["params"],
        "log": job["log"][-120:],
    }

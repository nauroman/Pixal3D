# Project Knowledge

Last updated: 2026-05-12, from inspection of the current Pixal3D project folder.

This file is the handoff note for future work in this repository. It records the current project shape, runtime assumptions, local state, and important implementation details.

## Purpose

This project is a local UI wrapper around TencentARC Pixal3D. It provides:

- an HTML/CSS/JavaScript interface for image upload and generation controls;
- a FastAPI backend for status checks, job creation, logs, and GLB serving;
- a Three.js GLB viewer with textured, solid, and wireframe modes;
- scripts for Windows setup, WSL CUDA backend setup, model downloads, and launching.

The practical goal is image-to-textured-GLB generation on this PC. The UI can run from Windows, but real Pixal3D inference is Linux/CUDA-first and is expected to run through WSL.

## Current Repo State

- Git branch observed: `master`.
- Recent commits observed:
  - `3b9532e Add reusable export-state redecimation workflow`
  - `54fbeab Fix Run action to launch WSL Pixal3D backend`
  - `2b7021b Fix Pixal3D run action to use WSL backend`
- At the time this file was created, these files already had uncommitted changes and should not be overwritten casually:
  - `app/server.py`
  - `static/app.js`
- The uncommitted changes add friendlier generation failure diagnosis in the backend and more robust frontend polling/error display when a job disappears or fails.
- `PROJECT_KNOWLEDGE.md` did not exist before this handoff file was added.

## Important Directories

- `app/`: FastAPI backend and Pixal3D runner.
- `static/`: browser UI and Three.js viewer.
- `scripts/`: setup, launch, WSL, and model download scripts.
- `engine/`: generated WSL scripts, pid files, smoke-job marker, and logs.
- `models/`: local Hugging Face model snapshots.
- `vendor/`: local clones of upstream inference repositories.
- `uploads/`: uploaded input images by job id.
- `outputs/`: generated job outputs, logs, GLBs, and reusable export states.
- `.venv/`: Windows Python virtual environment for the UI server.
- `node_modules/`: local Node dependencies, mainly Three.js.

Generated or heavy directories are intentionally ignored by git through `.gitignore`: `.venv/`, `.pixal3d-venv/`, `.codex/`, `node_modules/`, `vendor/`, `models/`, `uploads/`, `outputs/`, selected `engine` files, Python cache files, and OS metadata files.

## Installed Local Assets Observed

Vendor repositories present:

- `vendor/Pixal3D`
- `vendor/TRELLIS.2`

Model directories present:

- `models/Pixal3D`
- `models/dinov3-vitl16-pretrain-lvd1689m`
- `models/moge-2-vitl`
- `models/BiRefNet`
- `models/RMBG-2.0`

`models/RMBG-2.0` is optional and gated on Hugging Face. The default public background remover is `ZhengPeng7/BiRefNet`, but `scripts/download_models.py` patches `models/Pixal3D/pipeline.json` to prefer `models/RMBG-2.0` when that folder contains a valid Transformers checkpoint.

## Launch And Setup

Main launch command:

```powershell
.\launch.ps1
```

`package.json` also exposes:

```powershell
npm start
```

which runs `powershell -ExecutionPolicy Bypass -File ./launch.ps1`.

Useful launch flags:

- `.\launch.ps1 -Backend Auto`: default; uses WSL if ready, otherwise Windows.
- `.\launch.ps1 -Backend Wsl`: force WSL backend.
- `.\launch.ps1 -Backend Windows`: force Windows server process.
- `.\launch.ps1 -NoBrowser`: start server without opening a browser.
- `.\launch.ps1 -ForceSetup`: rerun setup where supported.

Default port is `7868`.

Setup commands from `README.md`:

```powershell
.\scripts\install-wsl.ps1
.\scripts\setup-wsl-backend.ps1
.\scripts\launch-wsl.ps1
.\scripts\download-models.ps1
```

Windows UI dependency setup is handled by:

```powershell
.\scripts\setup-app.ps1
```

It creates `.venv`, installs `requirements-app.txt`, installs npm dependencies, and clones `vendor/Pixal3D` plus `vendor/TRELLIS.2` unless `-SkipRepoClone` is used.

## Runtime Dependencies

Python app dependencies in `requirements-app.txt`:

- `fastapi==0.124.0`
- `uvicorn[standard]==0.38.0`
- `python-multipart==0.0.20`
- `huggingface_hub>=1.3.5,<2.0.0`
- `pillow==12.0.0`

Node dependency:

- `three ^0.181.2`

WSL backend setup creates/uses a conda environment named `pixal3d` with Python 3.10, PyTorch 2.6.0 CUDA 12.4 wheels, Pixal3D requirements, TRELLIS/Pixal3D CUDA extension dependencies, and a local NATTEN CUDA smoke test/rebuild path.

## Backend Implementation

`app/server.py` owns the local API.

Key constants:

- `ROOT`: repository root.
- `STATIC_DIR`: `static/`.
- `UPLOADS_DIR`: `uploads/`.
- `OUTPUTS_DIR`: `outputs/`.
- `MODELS_DIR`: `models/`.
- `PIXAL3D_DIR`: `vendor/Pixal3D`.
- `TRELLIS2_DIR`: `vendor/TRELLIS.2`.
- `ENGINE_DIR`: `engine/`.
- `MIN_SAFE_DECIMATION_TARGET`: `30000`.
- `TEXTURE_SIZE_OPTIONS`: `1024`, `2048`, `4096`.

Mounted static paths:

- `/static`
- `/outputs`
- `/uploads`
- `/three`

API endpoints:

- `GET /`: serves `static/index.html`.
- `GET /api/status`: reports repo, model, GPU, WSL, Node/Three, and engine readiness.
- `POST /api/jobs`: accepts an uploaded image and generation settings, creates a job, stores upload/output paths, and starts generation in a daemon thread.
- `GET /api/jobs/{job_id}`: returns the current public job state from in-memory `jobs`.
- `POST /api/jobs/{job_id}/exports`: re-exports a completed job from `export_state.pt` with new decimation/texture settings.

Important behavior:

- Job metadata lives in memory and is lost on server restart.
- Uploaded inputs and output files remain on disk under `uploads/<job_id>/` and `outputs/<job_id>/`.
- Re-export is only available when the completed job has an existing `export_state.pt`.
- If a requested re-export file already exists, the backend reuses it instead of rerunning export.
- Decimation values below `30000` are normalized upward to `30000`.
- Texture size is validated against `1024`, `2048`, and `4096`.
- Resolution is validated against `1024` and `1536`.
- Attention backend is validated against `flash_attn`, `flash_attn_3`, and `xformers`.

The current dirty backend change adds `_diagnose_failure(job)` with special messages for:

- CUDA driver/device-not-ready failures;
- CUDA out-of-memory failures;
- CUDA not available;
- missing Pixal3D backend files;
- generic pre-export generation failure.

## Pixal3D Runner

`app/pixal3d_runner.py` is the local inference/export CLI called by the server.

Main capabilities:

- loads Pixal3D from `--pixal3d-dir`;
- prefers local model folders via `PIXAL3D_MODELS_DIR`;
- replaces Pixal3D DINO config model names with local `models/dinov3-vitl16-pretrain-lvd1689m` when present;
- loads MoGe-2 camera estimation from `models/moge-2-vitl/model.pt` when present;
- preprocesses the image through Pixal3D;
- estimates camera params;
- runs the `1024_cascade` or `1536_cascade` Pixal3D pipeline;
- supports `--low-vram`;
- saves reusable export state through `--state-output`;
- re-exports from saved state through `--state-input`;
- exports GLB with WebP texture extension enabled;
- rotates the generated model before export.

Runner arguments include:

- `--seed`
- `--resolution`
- `--ss-steps`
- `--shape-steps`
- `--tex-steps`
- `--decimation-target`
- `--texture-size`
- `--max-num-tokens`
- `--attention-backend`
- `--low-vram`
- `--state-output`
- `--state-input`

Pixal3D generation requires CUDA. If `torch.cuda.is_available()` is false, the runner raises an error.

## Frontend Implementation

`static/index.html` defines the UI:

- status panel for GPU, model files, and engine;
- image drop/select input;
- generation controls for seed, resolution, sparse/shape/texture steps;
- export/backend controls for decimation, texture size, attention backend, max tokens, and low VRAM;
- Generate and Save GLB actions;
- viewer toolbar with mode and reset controls;
- backend log panel.

`static/app.js` owns UI state and backend communication:

- refreshes `/api/status`;
- handles image input, drag/drop, and preview;
- submits `POST /api/jobs`;
- polls `GET /api/jobs/{job_id}` every 1.5 seconds;
- loads completed GLBs into the viewer;
- disables generation/export controls while jobs are busy;
- triggers re-export on decimation or texture-size change;
- formats duration and current export params;
- displays backend logs.

The current dirty frontend change adds a try/catch around polling so a vanished job or bad response shows `Job unavailable`, clears the active job, re-enables controls, and tells the user to start a fresh generation.

`static/viewer.js` owns Three.js rendering:

- uses `OrbitControls` and `GLTFLoader`;
- sets renderer color space and tone mapping;
- has hemisphere, key, and fill lights;
- shows a grid helper;
- supports `Wire`, `Solid`, and `Textured` view modes;
- disposes previous model materials/textures before loading a new model;
- recenters loaded GLB and frames the camera;
- keeps an animation loop with resize and damping.

## Model Download Logic

`scripts/download_models.py` downloads these Hugging Face repositories:

- `TencentARC/Pixal3D` into `models/Pixal3D` with only `pipeline.json`, `ckpts/*`, `README.md`, and `LICENSE`.
- `camenduru/dinov3-vitl16-pretrain-lvd1689m` into `models/dinov3-vitl16-pretrain-lvd1689m`.
- `Ruicheng/moge-2-vitl` into `models/moge-2-vitl`.
- `ZhengPeng7/BiRefNet` into `models/BiRefNet`.

Flags:

- `--skip-existing`
- `--core-only`
- `--no-prefer-rmbg2`
- `--models-dir`

After download, it patches `models/Pixal3D/pipeline.json` to point to local background-removal and DINO model paths.

## WSL Details

`scripts/setup-wsl-backend.ps1`:

- verifies WSL is installed;
- installs Linux build tools and libraries as needed;
- installs Miniforge if missing;
- creates/updates conda env `pixal3d`;
- installs PyTorch CUDA 12.4 wheels;
- installs app and Pixal3D requirements;
- installs a specific `utils3d` source and then force-reinstalls a Pixal3D-compatible `utils3d` wheel;
- tests NATTEN CUDA;
- if needed, rebuilds NATTEN 0.21.0 for the local CUDA GPU architecture;
- runs `python scripts/download_models.py --skip-existing`;
- prints CUDA and GPU availability.

`launch.ps1` generates WSL probe/launch scripts under `engine/`, starts uvicorn inside WSL when selected, and uses the WSL IP URL for browser access.

Recent engine logs showed a previous WSL uvicorn process started on `http://0.0.0.0:7868` and served `/` plus `/api/status`. The same log also showed a WSL warning: `Failed to mount E:\, see dmesg for more details.` Treat that as an environment warning unless it blocks access to this project path.

At capture time, a Windows `Get-NetTCPConnection` check did not show a listener on local port `7868`.

## Known Local Runtime Markers

- `engine/last-smoke-job.txt` contained job id `3a1340ae99244e33b0560c876cba5b97`.
- Several output job directories existed under `outputs/`, including the smoke-job id above.
- `engine/server.out.log` and `engine/server.err.log` had recent WSL uvicorn/status lines.

## Practical Workflow For Future Edits

For code edits:

1. Check `git status --short --branch` first because the worktree may already be dirty.
2. Avoid touching `vendor/`, `models/`, `uploads/`, `outputs/`, and generated `engine/*.generated.sh` files unless the task explicitly requires it.
3. Preserve the current uncommitted failure-diagnosis and frontend polling changes unless the user asks to replace them.
4. Use narrow patches in `app/server.py`, `app/pixal3d_runner.py`, or `static/*` depending on the requested behavior.
5. For frontend behavior, verify through the local page when possible.
6. For backend behavior, verify at least with import/compile checks and `/api/status` when a server is running.
7. For real generation issues, WSL/CUDA state is decisive; do not assume Windows-only checks prove Pixal3D inference readiness.

Useful non-destructive checks:

```powershell
git status --short --branch
.\.venv\Scripts\python.exe -m py_compile app\server.py app\pixal3d_runner.py
Invoke-WebRequest -Uri http://127.0.0.1:7868/api/status -UseBasicParsing
```

For WSL launch verification, prefer:

```powershell
.\launch.ps1 -Backend Wsl -NoBrowser
```

or, if setup must be rerun:

```powershell
.\launch.ps1 -Backend Wsl -ForceSetup -NoBrowser
```

## Open Questions And Gaps

- There is no test script in `package.json`.
- No unit test files were observed.
- The current local model directories were observed by presence only; this file does not prove every checkpoint is complete or valid.
- Real Pixal3D generation was not rerun while creating this file.
- Server job state is memory-only, so old output directories may not correspond to retrievable `/api/jobs/{id}` entries after restart.

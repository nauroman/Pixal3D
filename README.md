# Pixal3D Local UI

This project wraps TencentARC Pixal3D in a local HTML page with image upload,
generation controls, a Three.js GLB viewer, and a download link for the
generated textured model.

## What is installed here

- `vendor/Pixal3D`: official Pixal3D source.
- `vendor/TRELLIS.2`: official TRELLIS.2 source used by Pixal3D.
- `app/server.py`: local FastAPI server.
- `static/`: local HTML/CSS/JS viewer.
- `models/`: local Hugging Face model snapshots after download.

## Windows usage

The web UI itself runs on Windows:

```powershell
.\launch.ps1
```

Official Pixal3D inference currently depends on Linux CUDA extension packages
from TRELLIS.2 (`flash-attn`, `o-voxel`, `flexgemm`, `nvdiffrast`,
`nvdiffrec`). On Windows, run the actual generation backend through WSL:

```powershell
.\scripts\install-wsl.ps1
# reboot if Windows asks
.\scripts\setup-wsl-backend.ps1
.\scripts\launch-wsl.ps1
```

Model files can be downloaded separately:

```powershell
.\scripts\download-models.ps1
```

The main Pixal3D checkpoint is roughly 23 GB. Extra local helper models are
also downloaded for DINOv3 features, camera estimation, and background removal.

## Optional RMBG-2.0 background remover

`briaai/RMBG-2.0` is a gated Hugging Face model. The setup uses public
`ZhengPeng7/BiRefNet` by default. To use RMBG-2.0 instead, request access on
Hugging Face, log in locally, then download it:

```powershell
.\.venv\Scripts\hf.exe auth login
.\.venv\Scripts\hf.exe download briaai/RMBG-2.0 --local-dir .\models\RMBG-2.0
.\.venv\Scripts\python.exe .\scripts\download_models.py --skip-existing
```

The last command patches `models/Pixal3D/pipeline.json` to prefer
`models/RMBG-2.0` when that folder exists.

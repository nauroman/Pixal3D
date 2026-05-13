$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Get-WslPath {
    param([string]$WindowsPath)

    $output = & wsl.exe --exec wslpath -a $WindowsPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        throw "Could not convert Windows path to WSL path: $WindowsPath"
    }
    return ($output -join "`n").Trim()
}

$wslStatus = wsl --list --verbose 2>&1
if ($LASTEXITCODE -ne 0 -or (($wslStatus -join "`n") -match "not installed")) {
    throw "WSL is not installed. Run scripts/install-wsl.ps1 first, reboot if Windows asks, then run this script again."
}

$bashTemplate = @'
set -e
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
cd "$project_root"

if ! command -v gcc >/dev/null 2>&1 || ! command -v git-lfs >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1 || [ ! -e /usr/include/jpeglib.h ]; then
  sudo apt update
  sudo apt install -y curl git git-lfs build-essential ninja-build libjpeg-dev
fi

if ! command -v wget >/dev/null 2>&1; then
  sudo apt install -y wget
fi

if [ ! -d "$HOME/miniforge3" ]; then
  wget -O /tmp/miniforge.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
  bash /tmp/miniforge.sh -b -p "$HOME/miniforge3"
fi

source "$HOME/miniforge3/etc/profile.d/conda.sh"
if ! conda env list | awk '{print $1}' | grep -qx pixal3d; then
  conda create -y -n pixal3d python=3.10 pip
else
  conda install -y -n pixal3d pip
fi
conda activate pixal3d

python -m pip install --upgrade pip wheel setuptools packaging ninja
python -m pip install torch==2.6.0 torchvision==0.21.0 --index-url https://download.pytorch.org/whl/cu124
python -m pip install -r requirements-app.txt
python -m pip install -r "$project_root/vendor/Pixal3D/requirements-hfdemo.txt"
python -m pip install git+https://github.com/EasternJournalist/utils3d.git@9a4eb15e4021b67b12c460c7057d642626897ec8

cd "$project_root/vendor/Pixal3D"
python -m pip install --force-reinstall --no-deps https://github.com/LDYang694/Storages/releases/download/20260430/utils3d-0.0.2-py3-none-any.whl

cd "$project_root"
if ! python - <<'PY'
import torch
from natten.functional import na2d
q = torch.randn(1, 8, 8, 2, 16, device="cuda", dtype=torch.float16)
na2d(q, q, q, kernel_size=3, dilation=1)
torch.cuda.synchronize()
PY
then
  echo "Rebuilding NATTEN for the local CUDA GPU..."
  conda install -y -c conda-forge -c nvidia cmake cuda-nvcc=12.4 cuda-cudart-dev=12.4 cuda-libraries-dev=12.4 gcc_linux-64=11 gxx_linux-64=11

  CONDA_ENV_PREFIX="$(python -c 'import sys; print(sys.prefix)')"
  NATTEN_ARCH="$(python - <<'PY'
import torch
major, minor = torch.cuda.get_device_capability()
print(f"{major}.{minor}")
PY
)"
  NATTEN_WORK="$HOME/.cache/pixal3d/natten-0.21.0-sm${NATTEN_ARCH/./}"
  NATTEN_SRC="$NATTEN_WORK/src"
  NATTEN_BUILD="$NATTEN_WORK/build"
  mkdir -p "$NATTEN_WORK"
  if [ ! -d "$NATTEN_SRC/csrc" ]; then
    rm -rf "$NATTEN_SRC"
    mkdir -p "$NATTEN_WORK/download" "$NATTEN_SRC"
    python -m pip download --no-binary=:all: --no-build-isolation --no-deps -d "$NATTEN_WORK/download" natten==0.21.0
    tar -xzf "$NATTEN_WORK/download"/natten-0.21.0.tar.gz -C "$NATTEN_SRC" --strip-components=1
  fi

  python - <<PY
from pathlib import Path

patches = {
    Path("$NATTEN_SRC/third_party/cutlass/include/cutlass/array.h"): [
        ("return crbegin();", "return const_reverse_iterator(reinterpret_cast<const_pointer>(storage + kStorageElements));"),
        ("const_reverse_iterator crbegin() const {", "const_reverse_iterator crbegin() {"),
        ("return crend();", "return const_reverse_iterator(reinterpret_cast<const_pointer>(storage));"),
        ("const_reverse_iterator crend() const {", "const_reverse_iterator crend() {"),
    ],
    Path("$NATTEN_SRC/third_party/cutlass/include/cutlass/array_subbyte.h"): [
        ("const_reverse_iterator crbegin() const {", "const_reverse_iterator crbegin() {"),
        ("const_reverse_iterator crend() const {", "const_reverse_iterator crend() {"),
    ],
}

for path, replacements in patches.items():
    text = path.read_text()
    for old, new in replacements:
        text = text.replace(old, new)
    path.write_text(text)
PY

  rm -rf "$NATTEN_BUILD"
  mkdir -p "$NATTEN_BUILD/natten"
  EXT_SUFFIX="$(python -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or ".so")')"
  CUDA_HOME="$CONDA_ENV_PREFIX" CUDACXX="$CONDA_ENV_PREFIX/bin/nvcc" cmake "$NATTEN_SRC/csrc" \
    -DPYTHON_PATH="$CONDA_ENV_PREFIX/bin/python" \
    -DOUTPUT_FILE_NAME="natten/libnatten${EXT_SUFFIX}" \
    -DNATTEN_CUDA_ARCH_LIST="${NATTEN_ARCH/./}-real" \
    -DNATTEN_IS_WINDOWS=0 \
    -DIS_LIBTORCH_BUILT_WITH_CXX11_ABI=0 \
    -DCMAKE_CXX_COMPILER="$CONDA_ENV_PREFIX/bin/x86_64-conda-linux-gnu-g++" \
    -DCMAKE_CUDA_HOST_COMPILER="$CONDA_ENV_PREFIX/bin/x86_64-conda-linux-gnu-g++" \
    -S "$NATTEN_SRC/csrc" \
    -B "$NATTEN_BUILD"
  cmake --build "$NATTEN_BUILD" -j 1
  cp "$NATTEN_BUILD/natten/libnatten${EXT_SUFFIX}" "$CONDA_ENV_PREFIX/lib/python3.10/site-packages/natten/libnatten${EXT_SUFFIX}"

  python - <<'PY'
import torch
from natten.functional import na2d
q = torch.randn(1, 8, 8, 2, 16, device="cuda", dtype=torch.float16)
na2d(q, q, q, kernel_size=3, dilation=1)
torch.cuda.synchronize()
print("NATTEN CUDA test: ok")
PY
fi

cd "$project_root"
python scripts/download_models.py --skip-existing

python - <<'PY'
import torch
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PY
'@

$bash = $bashTemplate
$EngineDir = Join-Path $Root "engine"
New-Item -ItemType Directory -Force -Path $EngineDir | Out-Null
$SetupScriptPath = Join-Path $EngineDir "setup-wsl-backend.generated.sh"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($SetupScriptPath, $bash.Replace("`r`n", "`n"), $Utf8NoBom)
$WslScriptPath = Get-WslPath $SetupScriptPath

wsl.exe --exec bash "$WslScriptPath"

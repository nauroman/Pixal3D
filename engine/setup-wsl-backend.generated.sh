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
python scripts/download_models.py --skip-existing

python - <<'PY'
import torch
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PY

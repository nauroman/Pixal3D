set -e
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
cd "$project_root"
test -f "$HOME/miniforge3/etc/profile.d/conda.sh"
source "$HOME/miniforge3/etc/profile.d/conda.sh"
conda activate pixal3d
python - <<'PY'
import importlib.util

mods = ["torch", "o_voxel", "moge", "nvdiffrast", "flex_gemm", "cumesh", "natten"]
missing = [module for module in mods if importlib.util.find_spec(module) is None]
if missing:
    print("missing:" + ",".join(missing))
    raise SystemExit(1)

import transformers
import torch
if not torch.cuda.is_available():
    print("cuda:false")
    raise SystemExit(1)

print("ready")
PY
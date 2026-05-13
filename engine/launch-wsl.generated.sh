set -e
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
cd "$project_root"
source "$HOME/miniforge3/etc/profile.d/conda.sh"
conda activate pixal3d
exec python -m uvicorn app.server:app --host 0.0.0.0 --port 7868
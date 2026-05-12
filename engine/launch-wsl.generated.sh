set -e
cd "/mnt/c/Users/user/Documents/New project"
source "$HOME/miniforge3/etc/profile.d/conda.sh"
conda activate pixal3d
exec python -m uvicorn app.server:app --host 0.0.0.0 --port 7868
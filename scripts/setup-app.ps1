param(
    [switch]$SkipRepoClone
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Get-PythonForApp {
    $candidate = (& py -V:3.12 -c "import sys; print(sys.executable)" 2>$null)
    if (-not $candidate) {
        $candidate = (& python -c "import sys; print(sys.executable)" 2>$null)
    }
    if (-not $candidate) {
        throw "Python was not found. Install Python or adjust this script."
    }
    return $candidate.Trim()
}

if (-not (Test-Path ".venv\Scripts\python.exe")) {
    $python = Get-PythonForApp
    & $python -m venv .venv
}

& ".\.venv\Scripts\python.exe" -m pip install --upgrade pip
& ".\.venv\Scripts\python.exe" -m pip install -r requirements-app.txt

if (-not (Test-Path "node_modules\three")) {
    npm install
}

if (-not $SkipRepoClone) {
    if (-not (Test-Path "vendor\Pixal3D\.git")) {
        git clone --depth 1 https://github.com/TencentARC/Pixal3D vendor/Pixal3D
    }
    if (-not (Test-Path "vendor\TRELLIS.2\.git")) {
        git clone --depth 1 --recursive https://github.com/microsoft/TRELLIS.2 vendor/TRELLIS.2
    }
}

Write-Host "Local UI dependencies are ready."

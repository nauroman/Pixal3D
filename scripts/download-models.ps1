$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

& ".\scripts\setup-app.ps1" -SkipRepoClone
& ".\.venv\Scripts\python.exe" ".\scripts\download_models.py" --skip-existing

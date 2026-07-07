$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Invoke-CheckedCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    Write-Host ""
    Write-Host "> $FilePath $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $FilePath @Arguments
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
}

Invoke-CheckedCommand -FilePath ".\scripts\setup-app.ps1" -Arguments @("-SkipRepoClone")
Invoke-CheckedCommand -FilePath ".\.venv\Scripts\python.exe" -Arguments @(".\scripts\download_models.py", "--skip-existing")

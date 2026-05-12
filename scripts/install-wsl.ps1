$ErrorActionPreference = "Stop"

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $status = & wsl.exe --list --verbose 2>&1
    $wslExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

if ($wslExitCode -eq 0 -and ($status -join "`n") -notmatch "not installed") {
    Write-Host "WSL is already installed."
    exit 0
}

Write-Host "WSL is required for the official Pixal3D CUDA extension stack on Windows."
Write-Host "An elevated PowerShell window will open. A reboot may be required."

$command = "wsl --install"
Start-Process powershell -Verb RunAs -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $command

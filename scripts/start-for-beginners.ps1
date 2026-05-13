param(
    [ValidateSet("Auto", "Full", "Quick")]
    [string]$Mode = "Auto",
    [switch]$NoUpdate,
    [switch]$NoBrowser,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Write-Header {
    param([string]$Text)

    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)

    Write-Host ""
    Write-Host "[Pixal3D] $Text" -ForegroundColor Green
}

function Write-WarningText {
    param([string]$Text)

    Write-Host ""
    Write-Host "[Warning] $Text" -ForegroundColor Yellow
}

function Wait-ForUser {
    param([string]$Prompt = "Press Enter to continue")

    [void](Read-Host $Prompt)
}

function Show-Help {
    Write-Host "Pixal3D beginner launcher"
    Write-Host ""
    Write-Host "Normal beginner launch:"
    Write-Host "  Double-click START_PIXAL3D.bat"
    Write-Host ""
    Write-Host "Optional modes:"
    Write-Host "  START_PIXAL3D.bat -Mode Full     Full WSL/CUDA backend setup and launch"
    Write-Host "  START_PIXAL3D.bat -Mode Quick    Windows web UI only, without WSL backend setup"
    Write-Host "  START_PIXAL3D.bat -NoUpdate      Skip the safe git pull --ff-only step"
    Write-Host "  START_PIXAL3D.bat -NoBrowser     Start the server without opening a browser"
}

function Ask-YesNo {
    param(
        [string]$Question,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = (Read-Host "$Question $suffix").Trim().ToLowerInvariant()
        if (-not $answer) {
            return $DefaultYes
        }
        if ($answer -in @("y", "yes")) {
            return $true
        }
        if ($answer -in @("n", "no")) {
            return $false
        }
        Write-Host "Type Y/yes or N/no."
    }
}

function Select-LaunchMode {
    Write-Header "Pixal3D local launcher"
    Write-Host "This launcher prepares the project and opens the local HTML page in your browser."
    Write-Host ""
    Write-Host "Pixal3D has two parts:"
    Write-Host "  1. Windows UI: the web page for image upload, settings, and GLB preview."
    Write-Host "  2. WSL/CUDA backend: the heavy 3D generation engine that requires an NVIDIA GPU."
    Write-Host ""
    Write-Host "Choose a mode:"
    Write-Host "  1 - Full setup and launch with 3D generation. This can take a long time and requires WSL plus an NVIDIA GPU."
    Write-Host "  2 - Quick launch of the web UI only. This is useful for checking the page, but generation will not work without the backend."
    Write-Host "  3 - Exit."

    while ($true) {
        $answer = (Read-Host "Type 1, 2, or 3, then press Enter [1]").Trim()
        if (-not $answer) {
            return "Full"
        }
        switch ($answer) {
            "1" { return "Full" }
            "2" { return "Quick" }
            "3" { exit 0 }
            default { Write-Host "Please type 1, 2, or 3." }
        }
    }
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    Write-Host ""
    Write-Host "> $FilePath $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $FilePath @Arguments
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
    return $exitCode
}

function Update-CurrentPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath;$env:Path"
}

function Install-WingetPackage {
    param(
        [string]$DisplayName,
        [string]$Id,
        [string]$ManualUrl
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-WarningText "The winget command was not found. The launcher cannot install $DisplayName automatically on this Windows installation."
        Write-Host "I will open the manual download page. Install $DisplayName, close this window, then run START_PIXAL3D.bat again."
        Start-Process $ManualUrl
        Wait-ForUser
        exit 2
    }

    Write-Step "Installing $DisplayName through winget. If Windows asks for administrator permission, click Yes."
    Invoke-External -FilePath "winget" -Arguments @(
        "install",
        "--id",
        $Id,
        "--exact",
        "--source",
        "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
    Update-CurrentPath
}

function Test-PythonReady {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3.12 -c "import sys; print(sys.executable)" > $null 2> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $versionText = (& python -c "import sys; print(str(sys.version_info[0]) + '.' + str(sys.version_info[1]) + '.' + str(sys.version_info[2]))" 2> $null)
        if ($LASTEXITCODE -eq 0 -and $versionText) {
            try {
                return ([version]($versionText -join "").Trim() -ge [version]"3.10")
            } catch {
                return $false
            }
        }
    }
    return $false
}

function Ensure-Python {
    if (Test-PythonReady) {
        Write-Host "Python was found."
        return
    }

    Write-WarningText "Python was not found. Python is required for the local Pixal3D server."
    Install-WingetPackage `
        -DisplayName "Python 3.12" `
        -Id "Python.Python.3.12" `
        -ManualUrl "https://www.python.org/downloads/windows/"

    if (-not (Test-PythonReady)) {
        Write-WarningText "Python was installed, but this terminal window still cannot see the new python command."
        Write-Host "This is normal after some Windows installs. Close this window and run START_PIXAL3D.bat again."
        Wait-ForUser
        exit 2
    }
}

function Ensure-CommandPackage {
    param(
        [string]$Command,
        [string]$DisplayName,
        [string]$WingetId,
        [string]$ManualUrl,
        [string]$Why
    )

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "$DisplayName was found."
        return
    }

    Write-WarningText "$DisplayName was not found. $Why"
    Install-WingetPackage -DisplayName $DisplayName -Id $WingetId -ManualUrl $ManualUrl

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-WarningText "$DisplayName was installed, but this terminal window still cannot see the $Command command."
        Write-Host "Close this window and run START_PIXAL3D.bat again."
        Wait-ForUser
        exit 2
    }
}

function Ensure-BasicTools {
    Write-Step "Checking basic tools: Git, Python, and Node.js."
    Ensure-CommandPackage `
        -Command "git" `
        -DisplayName "Git" `
        -WingetId "Git.Git" `
        -ManualUrl "https://git-scm.com/download/win" `
        -Why "Git is required to download the official Pixal3D and TRELLIS.2 source repositories into the vendor folder."
    Ensure-Python
    Ensure-CommandPackage `
        -Command "npm" `
        -DisplayName "Node.js LTS" `
        -WingetId "OpenJS.NodeJS.LTS" `
        -ManualUrl "https://nodejs.org/" `
        -Why "Node.js is required to install Three.js for GLB preview in the browser."
}

function Update-RepositoryIfSafe {
    if ($NoUpdate) {
        Write-Host "Repository update skipped because -NoUpdate was passed."
        return
    }
    if (-not (Test-Path (Join-Path $Root ".git"))) {
        Write-Host "This folder does not look like a Git repository. Skipping git pull."
        return
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git was not found. Skipping repository update."
        return
    }

    Write-Step "Checking whether the project can be safely updated."
    $status = & git status --porcelain
    if ($LASTEXITCODE -ne 0) {
        Write-WarningText "Could not read git status. Continuing without an update."
        return
    }
    if ($status) {
        Write-WarningText "This folder has local changes. To avoid overwriting work, git pull was skipped."
        return
    }

    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $branch -eq "HEAD") {
        Write-Host "Git remote/branch is not configured for a normal pull. Skipping repository update."
        return
    }

    $code = Invoke-External -FilePath "git" -Arguments @("pull", "--ff-only") -AllowFailure
    if ($code -ne 0) {
        Write-WarningText "Automatic update failed. This does not block launch, so the current files will be used."
    }
}

function Setup-WindowsUi {
    Write-Step "Installing Windows UI dependencies and downloading vendor/Pixal3D plus vendor/TRELLIS.2 if missing."
    Write-Host "This creates .venv, installs Python packages from requirements-app.txt, and runs npm install."
    & (Join-Path $Root "scripts\setup-app.ps1")
}

function Test-WslInstalled {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }
    $output = & wsl.exe --status 2>&1
    return ($LASTEXITCODE -eq 0 -and (($output -join "`n") -notmatch "not installed"))
}

function Ensure-WslInstalled {
    if (Test-WslInstalled) {
        Write-Host "WSL was found."
        return
    }

    Write-WarningText "WSL is not installed. WSL is required because the official Pixal3D backend uses Linux CUDA libraries."
    Write-Host "An administrator PowerShell window will open and run: wsl --install"
    Write-Host "Beginner instructions:"
    Write-Host "  1. If Windows asks for administrator permission, click Yes."
    Write-Host "  2. Wait for WSL installation to finish."
    Write-Host "  3. If Windows asks for a reboot, reboot the computer."
    Write-Host "  4. After rebooting, run START_PIXAL3D.bat again."

    if (-not (Ask-YesNo "Open the WSL installer now?" $true)) {
        throw "The full Pixal3D backend cannot run on Windows without WSL."
    }

    & (Join-Path $Root "scripts\install-wsl.ps1")
    Wait-ForUser "After WSL installation and any required reboot, press Enter and run START_PIXAL3D.bat again"
    exit 10
}

function Test-NvidiaGpuVisible {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        return $false
    }
    & nvidia-smi > $null 2> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-WslQuiet {
    param([string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        $output = & wsl.exe --exec @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Get-WslPath {
    param([string]$WindowsPath)

    $result = Invoke-WslQuiet -Arguments @("wslpath", "-a", $WindowsPath)
    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return $null
    }
    return ($result.Output -join "`n").Trim()
}

function Test-WslBackendReady {
    if (-not (Test-WslInstalled)) {
        return $false
    }

    $engineDir = Join-Path $Root "engine"
    New-Item -ItemType Directory -Force -Path $engineDir | Out-Null
    $probeScriptPath = Join-Path $engineDir "probe-beginner.generated.sh"
    $probeScript = @'
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
import torch
if not torch.cuda.is_available():
    print("cuda:false")
    raise SystemExit(1)
print("ready")
PY
'@
    [System.IO.File]::WriteAllText($probeScriptPath, $probeScript.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    $wslProbeScriptPath = Get-WslPath $probeScriptPath
    if (-not $wslProbeScriptPath) {
        return $false
    }
    $result = Invoke-WslQuiet -Arguments @("bash", $wslProbeScriptPath)
    return ($result.ExitCode -eq 0 -and (($result.Output -join "`n") -match "ready"))
}

function Setup-WslBackend {
    Ensure-WslInstalled

    if (-not (Test-NvidiaGpuVisible)) {
        Write-WarningText "Windows cannot see an NVIDIA GPU through nvidia-smi."
        Write-Host "Full Pixal3D generation requires an NVIDIA GPU, a recent NVIDIA Driver, and CUDA support inside WSL."
        Write-Host "If this computer has no NVIDIA GPU, the UI can still open, but 3D generation will not work."
        if (-not (Ask-YesNo "Continue the heavy WSL backend setup anyway?" $false)) {
            return $false
        }
    }

    if (Test-WslBackendReady) {
        Write-Host "WSL/CUDA backend is already ready."
        return $true
    }

    Write-Step "Preparing the Pixal3D WSL/CUDA backend."
    Write-Host "This can take 30-90+ minutes. The script installs Linux packages, Miniforge, PyTorch CUDA, Pixal3D/TRELLIS dependencies, and model files."
    Write-Host "If WSL starts for the first time and asks for a user name:"
    Write-Host "  - type a simple lowercase name, for example pixal;"
    Write-Host "  - create an Ubuntu password;"
    Write-Host "  - password characters are invisible while you type; this is normal;"
    Write-Host "  - type the same password again to confirm it."
    Write-Host "If you see a [sudo] password prompt, type the same Ubuntu password."

    & (Join-Path $Root "scripts\setup-wsl-backend.ps1")

    if (-not (Test-WslBackendReady)) {
        Write-WarningText "Setup finished, but the backend readiness check still failed."
        Write-Host "The UI can still be opened now. For backend details, check engine/server.err.log or the error text printed above."
        return $false
    }

    return $true
}

function Start-Pixal3D {
    param([string]$Backend)

    Write-Step "Starting Pixal3D and opening the local HTML page."
    $arguments = @("-Backend", $Backend)
    if ($NoBrowser) {
        $arguments += "-NoBrowser"
    }
    & (Join-Path $Root "launch.ps1") @arguments
}

if ($Help) {
    Show-Help
    exit 0
}

try {
    if ($Mode -eq "Auto") {
        $Mode = Select-LaunchMode
    }

    Ensure-BasicTools
    Update-RepositoryIfSafe
    Setup-WindowsUi

    if ($Mode -eq "Quick") {
        Start-Pixal3D -Backend "Windows"
    } else {
        $backendReady = Setup-WslBackend
        if ($backendReady) {
            Start-Pixal3D -Backend "Wsl"
        } else {
            Write-WarningText "The full backend is not ready. Opening the Windows UI so the page can still be checked."
            Start-Pixal3D -Backend "Windows"
        }
    }

    Write-Host ""
    Write-Host "Done. If the browser opened, use the Pixal3D page there." -ForegroundColor Green
    Write-Host "To restart the server later, run START_PIXAL3D.bat again."
    exit 0
} catch {
    Write-Host ""
    Write-Host "[Error] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Beginner recovery steps:"
    Write-Host "  1. Read the last error above."
    Write-Host "  2. If Git, Python, or Node.js was just installed, close this window and run START_PIXAL3D.bat again."
    Write-Host "  3. If the error mentions WSL or Ubuntu, reboot Windows and run START_PIXAL3D.bat again."
    Write-Host "  4. If the error repeats, send the error text plus engine/server.out.log and engine/server.err.log to the person helping with this project."
    exit 1
}

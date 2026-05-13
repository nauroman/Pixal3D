param(
    [int]$Port = 7868,
    [ValidateSet("Auto", "Wsl", "Windows")]
    [string]$Backend = "Auto",
    [switch]$SkipSetup,
    [switch]$ForceSetup,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
Set-Location $Root

$Url = "http://127.0.0.1:$Port/"
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$LogDir = Join-Path $Root "engine"
$StdoutLog = Join-Path $LogDir "server.out.log"
$StderrLog = Join-Path $LogDir "server.err.log"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

New-Item -ItemType Directory -Force $LogDir | Out-Null

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

function Get-WslIp {
    $result = Invoke-WslQuiet -Arguments @("hostname", "-I")
    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return $null
    }

    return (($result.Output -join " ") -split "\s+" | Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" } | Select-Object -First 1)
}

function Test-WslBackend {
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

import transformers
import torch
if not torch.cuda.is_available():
    print("cuda:false")
    raise SystemExit(1)

print("ready")
PY
'@

    $probeScriptPath = Join-Path $LogDir "probe-wsl.generated.sh"
    [System.IO.File]::WriteAllText($probeScriptPath, $probeScript.Replace("`r`n", "`n"), $Utf8NoBom)
    $wslProbeScriptPath = Get-WslPath $probeScriptPath
    if (-not $wslProbeScriptPath) {
        return $false
    }

    $result = Invoke-WslQuiet -Arguments @("bash", $wslProbeScriptPath)
    return $result.ExitCode -eq 0 -and (($result.Output -join "`n") -match "ready")
}

function Stop-ExistingServers {
    param([bool]$IncludeWsl)

    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -and $_.OwningProcess -ne $PID } |
        Select-Object -ExpandProperty OwningProcess -Unique

    foreach ($processId in $listeners) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) {
            Write-Host "Stopping existing server on port $Port (PID $processId)..."
            Stop-Process -Id $processId -Force
        }
    }

    if ($IncludeWsl) {
        Invoke-WslQuiet -Arguments @("bash", "-lc", "pkill -f '[u]vicorn app.server:app.*--port $Port' || true") | Out-Null
    }

    foreach ($attempt in 1..20) {
        $stillListening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if (-not $stillListening) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
}

function Wait-ServerReady {
    param([System.Diagnostics.Process]$Process)

    foreach ($attempt in 1..60) {
        Start-Sleep -Milliseconds 500
        if ($Process.HasExited) {
            $stdout = if (Test-Path $StdoutLog) { Get-Content -Raw $StdoutLog } else { "" }
            $stderr = if (Test-Path $StderrLog) { Get-Content -Raw $StderrLog } else { "" }
            throw "Pixal3D UI server exited early.`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
        }

        try {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 | Out-Null
            return
        } catch {
            if ($attempt -eq 60) {
                throw "Pixal3D UI server did not become ready at $Url. Logs: $StdoutLog, $StderrLog"
            }
        }
    }
}

function Start-WindowsServer {
    if (-not $SkipSetup) {
        $needsSetup = $ForceSetup -or (
            -not (Test-Path $Python) -or
            -not (Test-Path (Join-Path $Root "node_modules\three")) -or
            -not (Test-Path (Join-Path $Root "vendor\Pixal3D")) -or
            -not (Test-Path (Join-Path $Root "vendor\TRELLIS.2"))
        )

        if ($needsSetup) {
            & ".\scripts\setup-app.ps1"
        }
    }

    if (-not (Test-Path $Python)) {
        throw "Python virtual environment is missing: $Python"
    }

    $serverArgs = @("-m", "uvicorn", "app.server:app", "--host", "127.0.0.1", "--port", "$Port")
    return Start-Process -FilePath $Python `
        -ArgumentList $serverArgs `
        -WorkingDirectory $Root `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -WindowStyle Hidden `
        -PassThru
}

function Start-WslServer {
    if ($ForceSetup) {
        & ".\scripts\setup-wsl-backend.ps1"
    }

    $wslRoot = Get-WslPath $Root
    if (-not $wslRoot) {
        throw "WSL is not available. Run .\scripts\install-wsl.ps1 first."
    }

    $launchScript = @'
set -e
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
cd "$project_root"
source "$HOME/miniforge3/etc/profile.d/conda.sh"
conda activate pixal3d
exec python -m uvicorn app.server:app --host 0.0.0.0 --port __PORT__
'@

    $launchScript = $launchScript.Replace("__PORT__", "$Port")
    $launchScriptPath = Join-Path $LogDir "launch-wsl.generated.sh"
    [System.IO.File]::WriteAllText($launchScriptPath, $launchScript.Replace("`r`n", "`n"), $Utf8NoBom)
    $wslLaunchScriptPath = Get-WslPath $launchScriptPath
    if (-not $wslLaunchScriptPath) {
        throw "Could not convert launch script path for WSL: $launchScriptPath"
    }

    return Start-Process -FilePath "wsl.exe" `
        -ArgumentList @("--exec", "bash", "`"$wslLaunchScriptPath`"") `
        -WorkingDirectory $Root `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -WindowStyle Hidden `
        -PassThru
}

$wslReady = $false
if ($Backend -ne "Windows") {
    $wslReady = Test-WslBackend
}

$selectedBackend = $Backend
if ($Backend -eq "Auto") {
    $selectedBackend = if ($wslReady) { "Wsl" } else { "Windows" }
}

if ($selectedBackend -eq "Wsl" -and -not $wslReady -and -not $ForceSetup) {
    throw "WSL Pixal3D backend is not ready. Run .\scripts\setup-wsl-backend.ps1 or launch with -ForceSetup."
}

if ($selectedBackend -eq "Wsl") {
    $wslIp = Get-WslIp
    if (-not $wslIp) {
        throw "Could not determine WSL IP address."
    }
    $Url = "http://${wslIp}:$Port/"
}

Stop-ExistingServers -IncludeWsl:($selectedBackend -eq "Wsl")

if ($selectedBackend -eq "Wsl") {
    $server = Start-WslServer
} else {
    $server = Start-WindowsServer
}

Write-Host "Pixal3D UI server started on $Url with $selectedBackend backend (PID $($server.Id))."
Wait-ServerReady -Process $server

if (-not $NoBrowser) {
    Start-Process $Url
    Write-Host "Opened $Url"
} else {
    Write-Host "Ready at $Url"
}

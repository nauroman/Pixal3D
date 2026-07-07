param(
    [switch]$SkipRepoClone
)

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

function Invoke-PythonProbe {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        $output = & $FilePath @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0 -or -not $output) {
        return $null
    }

    return ($output -join "`n").Trim()
}

function Get-PythonFromCandidate {
    param(
        [string]$FilePath,
        [string[]]$PrefixArguments = @()
    )

    $probeCode = "import sys; print(str(sys.version_info[0]) + '.' + str(sys.version_info[1]) + '.' + str(sys.version_info[2])); print(sys.executable)"
    $probeOutput = Invoke-PythonProbe -FilePath $FilePath -Arguments ($PrefixArguments + @("-c", $probeCode))
    if (-not $probeOutput) {
        return $null
    }

    $lines = $probeOutput -split "\r?\n"
    if ($lines.Count -lt 2) {
        return $null
    }

    try {
        if ([version]$lines[0].Trim() -lt [version]"3.10") {
            return $null
        }
    } catch {
        return $null
    }

    $executable = $lines[1].Trim()
    if (-not $executable -or -not (Test-Path $executable)) {
        return $null
    }

    return $executable
}

function Ensure-GitRepository {
    param(
        [string]$RepoUrl,
        [string]$TargetPath,
        [string[]]$CloneArguments = @(),
        [switch]$UpdateSubmodules
    )

    if (Test-Path (Join-Path $TargetPath ".git")) {
        if ($UpdateSubmodules) {
            Invoke-CheckedCommand -FilePath "git" -Arguments @("-C", $TargetPath, "submodule", "update", "--init", "--recursive")
        }
        return
    }

    if (Test-Path $TargetPath) {
        $existingItems = Get-ChildItem -Force -Path $TargetPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($existingItems) {
            throw "Cannot download $RepoUrl because $TargetPath already exists but is not a Git repository. Remove that partial folder, then run START_PIXAL3D.bat again."
        }
    }

    $parent = Split-Path -Parent $TargetPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Invoke-CheckedCommand -FilePath "git" -Arguments (@("clone") + $CloneArguments + @($RepoUrl, $TargetPath))
    if ($UpdateSubmodules) {
        Invoke-CheckedCommand -FilePath "git" -Arguments @("-C", $TargetPath, "submodule", "update", "--init", "--recursive")
    }
}

function Get-PythonForApp {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($versionArg in @("-3.12", "-3.11", "-3.10", "-3")) {
            $candidate = Get-PythonFromCandidate -FilePath "py" -PrefixArguments @($versionArg)
            if ($candidate) {
                return $candidate
            }
        }
    }

    if (Get-Command python -ErrorAction SilentlyContinue) {
        $candidate = Get-PythonFromCandidate -FilePath "python"
        if ($candidate) {
            return $candidate
        }
    }

    throw "Python 3.10 or newer was not found. Install Python 3.12, then run START_PIXAL3D.bat again."
}

if (-not (Test-Path ".venv\Scripts\python.exe")) {
    $python = Get-PythonForApp
    Invoke-CheckedCommand -FilePath $python -Arguments @("-m", "venv", ".venv")
}

$venvPython = Join-Path $Root ".venv\Scripts\python.exe"
Invoke-CheckedCommand -FilePath $venvPython -Arguments @("-m", "pip", "install", "--upgrade", "pip")
Invoke-CheckedCommand -FilePath $venvPython -Arguments @("-m", "pip", "install", "-r", "requirements-app.txt")

if (-not (Test-Path "node_modules\three")) {
    Invoke-CheckedCommand -FilePath "npm" -Arguments @("install")
}

if (-not $SkipRepoClone) {
    Ensure-GitRepository `
        -RepoUrl "https://github.com/TencentARC/Pixal3D" `
        -TargetPath "vendor\Pixal3D" `
        -CloneArguments @("--depth", "1")

    Ensure-GitRepository `
        -RepoUrl "https://github.com/microsoft/TRELLIS.2" `
        -TargetPath "vendor\TRELLIS.2" `
        -CloneArguments @("--depth", "1", "--recursive") `
        -UpdateSubmodules
}

Write-Host "Local UI dependencies are ready."

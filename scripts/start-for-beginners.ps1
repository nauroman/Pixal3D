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
    Write-Host "[Внимание] $Text" -ForegroundColor Yellow
}

function Wait-ForUser {
    param([string]$Prompt = "Нажмите Enter, чтобы продолжить")

    [void](Read-Host $Prompt)
}

function Show-Help {
    Write-Host "Pixal3D beginner launcher"
    Write-Host ""
    Write-Host "Обычный запуск для новичка:"
    Write-Host "  Дважды нажмите START_PIXAL3D.bat"
    Write-Host ""
    Write-Host "Дополнительные режимы:"
    Write-Host "  START_PIXAL3D.bat -Mode Full     Полная настройка WSL/CUDA backend и запуск"
    Write-Host "  START_PIXAL3D.bat -Mode Quick    Только Windows UI, без настройки WSL backend"
    Write-Host "  START_PIXAL3D.bat -NoUpdate      Не делать безопасный git pull --ff-only"
    Write-Host "  START_PIXAL3D.bat -NoBrowser     Запустить сервер, но не открывать браузер"
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
        if ($answer -in @("y", "yes", "д", "да")) {
            return $true
        }
        if ($answer -in @("n", "no", "н", "нет")) {
            return $false
        }
        Write-Host "Введите Y/да или N/нет."
    }
}

function Select-LaunchMode {
    Write-Header "Pixal3D local launcher"
    Write-Host "Этот файл подготовит проект и откроет локальную HTML-страницу в браузере."
    Write-Host ""
    Write-Host "Pixal3D состоит из двух частей:"
    Write-Host "  1. Windows UI: веб-страница, загрузка картинки, просмотр GLB."
    Write-Host "  2. WSL/CUDA backend: тяжелая генерация 3D-модели через NVIDIA GPU."
    Write-Host ""
    Write-Host "Выберите режим:"
    Write-Host "  1 - Полная настройка и запуск с 3D-генерацией. Долго, нужны WSL и NVIDIA GPU. Рекомендуется для первого полноценного запуска."
    Write-Host "  2 - Быстрый запуск только интерфейса. Подходит, чтобы проверить страницу; генерация не заработает без backend."
    Write-Host "  3 - Выход."

    while ($true) {
        $answer = (Read-Host "Введите 1, 2 или 3 и нажмите Enter [1]").Trim()
        if (-not $answer) {
            return "Full"
        }
        switch ($answer) {
            "1" { return "Full" }
            "2" { return "Quick" }
            "3" { exit 0 }
            default { Write-Host "Нужно ввести 1, 2 или 3." }
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
        throw "Команда завершилась с ошибкой $exitCode`: $FilePath $($Arguments -join ' ')"
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
        Write-WarningText "На этом Windows не найдена команда winget. Автоматически поставить $DisplayName не получится."
        Write-Host "Открою страницу установки. Установите $DisplayName, закройте это окно и запустите START_PIXAL3D.bat снова."
        Start-Process $ManualUrl
        Wait-ForUser
        exit 2
    }

    Write-Step "Устанавливаю $DisplayName через winget. Если Windows покажет окно разрешения администратора, нажмите Yes/Да."
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
        Write-Host "Python найден."
        return
    }

    Write-WarningText "Python не найден. Он нужен для локального сервера Pixal3D."
    Install-WingetPackage `
        -DisplayName "Python 3.12" `
        -Id "Python.Python.3.12" `
        -ManualUrl "https://www.python.org/downloads/windows/"

    if (-not (Test-PythonReady)) {
        Write-WarningText "Python установлен, но это окно еще не видит новую команду python."
        Write-Host "Это обычная ситуация после установки. Закройте это окно и запустите START_PIXAL3D.bat снова."
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
        Write-Host "$DisplayName найден."
        return
    }

    Write-WarningText "$DisplayName не найден. $Why"
    Install-WingetPackage -DisplayName $DisplayName -Id $WingetId -ManualUrl $ManualUrl

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-WarningText "$DisplayName установлен, но это окно еще не видит команду $Command."
        Write-Host "Закройте это окно и запустите START_PIXAL3D.bat снова."
        Wait-ForUser
        exit 2
    }
}

function Ensure-BasicTools {
    Write-Step "Проверяю базовые программы: Git, Python и Node.js."
    Ensure-CommandPackage `
        -Command "git" `
        -DisplayName "Git" `
        -WingetId "Git.Git" `
        -ManualUrl "https://git-scm.com/download/win" `
        -Why "Git нужен, чтобы скачать официальные исходники Pixal3D и TRELLIS.2 в папку vendor."
    Ensure-Python
    Ensure-CommandPackage `
        -Command "npm" `
        -DisplayName "Node.js LTS" `
        -WingetId "OpenJS.NodeJS.LTS" `
        -ManualUrl "https://nodejs.org/" `
        -Why "Node.js нужен, чтобы поставить Three.js для просмотра GLB в браузере."
}

function Update-RepositoryIfSafe {
    if ($NoUpdate) {
        Write-Host "Обновление репозитория пропущено: указан -NoUpdate."
        return
    }
    if (-not (Test-Path (Join-Path $Root ".git"))) {
        Write-Host "Папка не выглядит как git-репозиторий. Пропускаю git pull."
        return
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git не найден, обновление репозитория пропущено."
        return
    }

    Write-Step "Проверяю, можно ли безопасно обновить проект."
    $status = & git status --porcelain
    if ($LASTEXITCODE -ne 0) {
        Write-WarningText "Не удалось прочитать git status. Продолжаю без обновления."
        return
    }
    if ($status) {
        Write-WarningText "В папке есть локальные изменения. Чтобы ничего не перезаписать, git pull пропущен."
        return
    }

    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $branch -eq "HEAD") {
        Write-Host "Git remote/branch не настроен для обычного pull. Пропускаю обновление."
        return
    }

    $code = Invoke-External -FilePath "git" -Arguments @("pull", "--ff-only") -AllowFailure
    if ($code -ne 0) {
        Write-WarningText "Автообновление не получилось. Это не мешает запуску, продолжаю с текущими файлами."
    }
}

function Setup-WindowsUi {
    Write-Step "Ставлю зависимости Windows UI и скачиваю vendor/Pixal3D + vendor/TRELLIS.2, если их нет."
    Write-Host "Это создаст .venv, поставит Python packages из requirements-app.txt и выполнит npm install."
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
        Write-Host "WSL найден."
        return
    }

    Write-WarningText "WSL не установлен. WSL нужен, потому что официальный Pixal3D backend использует Linux CUDA-библиотеки."
    Write-Host "Сейчас откроется PowerShell от администратора и выполнит: wsl --install"
    Write-Host "Что делать новичку:"
    Write-Host "  1. Если Windows спросит разрешение администратора, нажмите Yes/Да."
    Write-Host "  2. Дождитесь завершения установки."
    Write-Host "  3. Если Windows попросит перезагрузку, перезагрузите компьютер."
    Write-Host "  4. После перезагрузки снова запустите START_PIXAL3D.bat."

    if (-not (Ask-YesNo "Открыть установку WSL сейчас?" $true)) {
        throw "Без WSL полный backend Pixal3D на Windows не запустится."
    }

    & (Join-Path $Root "scripts\install-wsl.ps1")
    Wait-ForUser "После завершения установки WSL/перезагрузки нажмите Enter и запустите START_PIXAL3D.bat снова"
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
        Write-WarningText "Windows не видит NVIDIA GPU через nvidia-smi."
        Write-Host "Полная генерация Pixal3D требует NVIDIA GPU, свежий NVIDIA Driver и CUDA внутри WSL."
        Write-Host "Если на компьютере нет NVIDIA GPU, интерфейс можно открыть, но генерация 3D не заработает."
        if (-not (Ask-YesNo "Все равно продолжить тяжелую настройку WSL backend?" $false)) {
            return $false
        }
    }

    if (Test-WslBackendReady) {
        Write-Host "WSL/CUDA backend уже готов."
        return $true
    }

    Write-Step "Настраиваю WSL/CUDA backend Pixal3D."
    Write-Host "Это может занять 30-90+ минут: будут ставиться Linux packages, Miniforge, PyTorch CUDA, Pixal3D/TRELLIS зависимости и модели."
    Write-Host "Если WSL запускается впервые и спрашивает имя пользователя:"
    Write-Host "  - введите простое имя латиницей, например pixal;"
    Write-Host "  - затем придумайте пароль Ubuntu;"
    Write-Host "  - при вводе пароля символы не показываются, это нормально;"
    Write-Host "  - повторите тот же пароль второй раз."
    Write-Host "Если появится запрос [sudo] password, введите этот Ubuntu-пароль."

    & (Join-Path $Root "scripts\setup-wsl-backend.ps1")

    if (-not (Test-WslBackendReady)) {
        Write-WarningText "Setup завершился, но проверка backend еще не прошла."
        Write-Host "Можно открыть UI сейчас, а детали ошибки посмотреть в engine/server.err.log или в тексте выше."
        return $false
    }

    return $true
}

function Start-Pixal3D {
    param([string]$Backend)

    Write-Step "Запускаю Pixal3D и открываю HTML-страницу."
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
            Write-WarningText "Полный backend не готов. Открываю Windows UI, чтобы можно было проверить страницу."
            Start-Pixal3D -Backend "Windows"
        }
    }

    Write-Host ""
    Write-Host "Готово. Если браузер открылся, используйте страницу Pixal3D там." -ForegroundColor Green
    Write-Host "Если нужно перезапустить сервер, просто запустите START_PIXAL3D.bat еще раз."
    exit 0
} catch {
    Write-Host ""
    Write-Host "[Ошибка] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Что сделать новичку:"
    Write-Host "  1. Прочитайте последнюю ошибку выше."
    Write-Host "  2. Если только что ставились Git/Python/Node.js, закройте это окно и запустите START_PIXAL3D.bat снова."
    Write-Host "  3. Если ошибка про WSL или Ubuntu, перезагрузите Windows и запустите START_PIXAL3D.bat снова."
    Write-Host "  4. Если ошибка повторяется, отправьте текст ошибки и файлы engine/server.out.log / engine/server.err.log тому, кто помогает с проектом."
    exit 1
}

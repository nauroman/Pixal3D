# Pixal3D Local UI

Локальная Windows-обертка для TencentARC Pixal3D: HTML-страница для загрузки изображения, настройки генерации, просмотра результата в Three.js и скачивания готового `.glb`.

## Самый простой запуск

1. Скачайте или склонируйте репозиторий.
2. Если это ZIP-архив, распакуйте его полностью. Не запускайте проект прямо из архива.
3. Откройте папку проекта в Проводнике Windows.
4. Дважды нажмите:

```bat
START_PIXAL3D.bat
```

BAT-файл сам запустит PowerShell-helper, проверит зависимости, поставит недостающие программы, подготовит проект, запустит локальный сервер и откроет HTML-страницу в браузере.

## Какой режим выбрать

При запуске `START_PIXAL3D.bat` появится меню:

```text
1 - Полная настройка и запуск с 3D-генерацией
2 - Быстрый запуск только интерфейса
3 - Выход
```

Выбирайте `1`, если хотите полноценную генерацию 3D-моделей. Это долгий первый запуск: нужны WSL, NVIDIA GPU, CUDA backend и большие model files.

Выбирайте `2`, если хотите быстро открыть локальную страницу и проверить интерфейс. В этом режиме веб-страница откроется, но генерация 3D не заработает, пока не настроен WSL/CUDA backend.

## Что устанавливается автоматически

`START_PIXAL3D.bat` проверяет и при необходимости ставит:

- Git - нужен для скачивания официальных исходников Pixal3D и TRELLIS.2 в `vendor/`.
- Python 3.12 - нужен для локального FastAPI-сервера.
- Node.js LTS / npm - нужен для установки Three.js viewer.
- Python virtual environment `.venv`.
- Python-зависимости из `requirements-app.txt`.
- npm-зависимости из `package.json`.
- `vendor/Pixal3D` и `vendor/TRELLIS.2`.

Если выбран полный режим, дополнительно настраивается:

- WSL / Ubuntu.
- Linux packages: build tools, git-lfs, ninja, libjpeg и другие.
- Miniforge.
- Conda environment `pixal3d`.
- PyTorch CUDA, Pixal3D/TRELLIS зависимости и CUDA extensions.
- Локальные модели в `models/`.

Главный checkpoint Pixal3D занимает примерно 23 GB. Вместе с helper-моделями, Python/Conda окружением и WSL лучше иметь 80-100 GB свободного места.

## Какие вопросы могут появиться

Скрипт специально объясняет каждый ввод, но основные случаи такие:

- Windows может спросить разрешение администратора. Это нужно для установки программ через `winget` или установки WSL. Нажмите `Yes` / `Да`.
- Если WSL ставится впервые, Ubuntu попросит создать пользователя. Введите простое имя латиницей, например `pixal`.
- Ubuntu попросит пароль. Придумайте пароль, введите его и повторите. Символы при вводе не показываются - это нормально.
- Если позже появится `[sudo] password`, введите тот же Ubuntu-пароль.
- Если Windows попросит перезагрузку после WSL, перезагрузите компьютер и снова запустите `START_PIXAL3D.bat`.

## Требования для полной 3D-генерации

Для интерфейса достаточно Windows, Python и Node.js.

Для реальной генерации Pixal3D нужны:

- Windows 10/11 с WSL.
- NVIDIA GPU.
- Свежий NVIDIA Driver, чтобы команда `nvidia-smi` работала в Windows.
- Много свободного места на диске.
- Стабильный интернет для скачивания моделей и зависимостей.

Если NVIDIA GPU нет, можно открыть UI, но backend генерации завершится ошибкой: Pixal3D требует CUDA.

## Ручные команды

Обычный запуск через BAT:

```bat
START_PIXAL3D.bat
```

Сразу полный режим:

```bat
START_PIXAL3D.bat -Mode Full
```

Сразу быстрый режим:

```bat
START_PIXAL3D.bat -Mode Quick
```

Запустить без безопасного обновления репозитория:

```bat
START_PIXAL3D.bat -NoUpdate
```

Запустить сервер, но не открывать браузер:

```bat
START_PIXAL3D.bat -NoBrowser
```

Старый прямой PowerShell-запуск тоже работает:

```powershell
.\launch.ps1
```

## Что делает автообновление

Если проект был скачан через Git и в папке нет локальных изменений, launcher выполняет:

```powershell
git pull --ff-only
```

Это безопасный режим обновления: он не перезаписывает ваши изменения. Если в папке уже есть измененные файлы, обновление пропускается и запуск продолжается.

## Структура проекта

- `START_PIXAL3D.bat` - главный файл для новичка.
- `scripts/start-for-beginners.ps1` - подробный helper, который ставит зависимости и объясняет действия.
- `launch.ps1` - запуск локального сервера и открытие браузера.
- `scripts/setup-app.ps1` - подготовка Windows UI.
- `scripts/install-wsl.ps1` - установка WSL через elevated PowerShell.
- `scripts/setup-wsl-backend.ps1` - подготовка WSL/CUDA backend.
- `scripts/download-models.ps1` - отдельная загрузка моделей.
- `app/server.py` - FastAPI server.
- `app/pixal3d_runner.py` - запуск Pixal3D inference/export.
- `static/` - HTML/CSS/JS интерфейс.
- `models/` - локальные модели после загрузки.
- `outputs/` - результаты генерации.
- `uploads/` - загруженные изображения.
- `vendor/` - официальные исходники Pixal3D и TRELLIS.2.

## Где смотреть ошибки

Если страница не открылась или backend упал, проверьте:

- `engine/server.out.log`
- `engine/server.err.log`
- `outputs/<job-id>/run.log`

Если ошибка произошла во время WSL setup, основной текст ошибки обычно находится прямо в окне запуска.

## Optional RMBG-2.0 background remover

По умолчанию используется публичная модель `ZhengPeng7/BiRefNet`. `briaai/RMBG-2.0` - gated Hugging Face model, для нее нужен доступ на Hugging Face.

После получения доступа можно скачать RMBG-2.0 отдельно:

```powershell
.\.venv\Scripts\hf.exe auth login
.\.venv\Scripts\hf.exe download briaai/RMBG-2.0 --local-dir .\models\RMBG-2.0
.\.venv\Scripts\python.exe .\scripts\download_models.py --skip-existing
```

Последняя команда обновит `models/Pixal3D/pipeline.json`, чтобы использовать `models/RMBG-2.0`, если эта папка существует.

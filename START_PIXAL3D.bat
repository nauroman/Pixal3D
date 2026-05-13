@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Pixal3D local launcher

set "ROOT=%~dp0"
set "HELPER=%ROOT%scripts\start-for-beginners.ps1"

if not exist "%HELPER%" (
    echo Pixal3D launcher helper was not found:
    echo %HELPER%
    echo.
    echo Make sure you extracted or cloned the whole repository, not just this BAT file.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Pixal3D setup or launch stopped with code %EXIT_CODE%.
    echo Read the message above. It usually says exactly what to install or retry.
)
echo Press any key to close this window.
pause >nul
exit /b %EXIT_CODE%

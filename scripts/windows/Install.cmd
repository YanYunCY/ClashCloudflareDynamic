@echo off
setlocal
chcp 65001 >nul
title Clash Cloudflare Dynamic Installer

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0install_wizard.ps1"
set "INSTALL_EXIT=%ERRORLEVEL%"

if not "%INSTALL_EXIT%"=="0" (
    echo.
    echo Installation failed. Review the message above, then press any key to close.
    pause >nul
)

exit /b %INSTALL_EXIT%

@echo off
setlocal
chcp 65001 >nul
title Clash Cloudflare Dynamic Installer

echo.
echo Select the client backend / 请选择客户端后端：
echo   [1] Clash Verge Rev / Mihomo
echo   [2] v2rayN / Xray
choice /C 12 /N /M "Choice / 选择: "
if errorlevel 2 goto :install_v2rayn

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0install_wizard.ps1"
goto :capture_exit

:install_v2rayn
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_v2rayn.ps1"

:capture_exit
set "INSTALL_EXIT=%ERRORLEVEL%"

if not "%INSTALL_EXIT%"=="0" (
    echo.
    echo Installation failed. Review the message above, then press any key to close.
    pause >nul
)

exit /b %INSTALL_EXIT%

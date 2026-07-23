@echo off
chcp 65001 >nul
set "APP=%LOCALAPPDATA%\ClashCloudflareDynamic"
cd /d "%APP%"
where python.exe >nul 2>nul
if %errorlevel%==0 (
  python.exe dynamic_selector.py
) else (
  py.exe -3 dynamic_selector.py
)
pause

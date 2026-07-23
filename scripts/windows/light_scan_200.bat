@echo off
chcp 65001 >nul
cd /d "%~dp0"
where python.exe >nul 2>nul
if %errorlevel%==0 (
  python.exe dynamic_selector.py --quick
) else (
  py.exe -3 dynamic_selector.py --quick
)
pause

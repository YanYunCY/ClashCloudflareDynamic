# Contributing

Contributions are welcome. Keep changes focused and include tests for behavior
that affects provider updates, Mihomo selection, scheduled tasks, notifications
or file recovery.

Before opening a pull request:

```powershell
python .\tools\privacy_check.py
python .\tools\build_release.py
Get-ChildItem .\src\clash_cloudflare_dynamic\*.py, .\tools\*.py | ForEach-Object { python -m py_compile $_.FullName }
$env:PYTHONPATH = Join-Path $PWD "src"
python -W error::ResourceWarning -m unittest discover -s .\tests\python -p "test_*.py" -v
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_install_hybrid.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_uninstall.ps1
```

Never include a real UUID, password, controller secret, SNI hostname, WebSocket
path, provider file, log, database or notification report in a commit or issue.

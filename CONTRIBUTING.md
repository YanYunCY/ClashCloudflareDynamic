# Contributing

Contributions are welcome. Keep changes focused and include tests for behavior
that affects provider updates, Mihomo selection, scheduled tasks, notifications
or file recovery.

Before opening a pull request:

```powershell
python .\tools\privacy_check.py
python -m py_compile dynamic_selector.py storage_maintenance.py health_monitor_launcher.py tools\privacy_check.py
python -m unittest -v test_dynamic_selector.py test_storage_maintenance.py test_privacy_check.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\test_setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test_install_hybrid.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test_uninstall.ps1
```

Never include a real UUID, password, controller secret, SNI hostname, WebSocket
path, provider file, log, database or notification report in a commit or issue.

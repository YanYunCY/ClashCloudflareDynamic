# Security Policy

## Supported version

Security fixes are applied to the latest revision on the `main` branch.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting when it is enabled for the
repository. Do not open a public issue containing credentials, controller
secrets, provider YAML, logs, notification reports, or a real node template.

If private reporting is unavailable, open a minimal issue without sensitive
data and ask the maintainer for a private contact channel.

## Credential boundary

The following files are intentionally ignored by Git and must remain local:

- `settings.json`
- `node_template.json`
- generated `clash_cloudflare_dynamic*.yaml`
- `providers/`, `logs/`, `backups/`, SQLite databases and state files

Before publishing a fork, run:

```powershell
python .\tools\privacy_check.py
git status --ignored --short
```

The privacy checker inspects ignored local configuration as well as publishable
files, but reports only the file name and finding category. Build release
archives from a reviewed Git commit instead of zipping a configured worktree.

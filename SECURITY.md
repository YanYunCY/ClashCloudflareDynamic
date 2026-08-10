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
files and Git-tracked sensitive paths, but reports only the file name and
finding category. Build release
archives from a reviewed Git commit with `python tools/build_release.py`
instead of zipping a configured worktree.

## Release installer

The Clash Windows Release wizard writes newly entered credentials to a per-run
directory under the current user's temporary directory and removes that
directory in a `finally` block. It never writes credentials into the extracted
Release directory and does not download or pipe remote scripts into
PowerShell. Reconfiguration passes only temporary file paths to the
transactional installer; secrets and node credentials are not command-line
arguments or status output.

The v2rayN installer reads the VMess UUID with masked console input and writes
it directly to the current user's installed `node_template.json`; it does not
write credentials into the extracted Release directory. The optional
`-PrepareOnly` mode writes only to the explicitly supplied temporary target and
returns before any Scheduled Task or v2rayN database mutation. The public
v2rayN backend has one generic `AUTO-CF` slot and only generates the VMess
template entered by the installing user; it does not infer, copy, or restore
other protocols, regions, exits, or database slots from the maintainer's
environment.

Mihomo or Xray must read the installed node template and managed profiles, so credentials
are necessarily stored in plaintext under the current user's LocalAppData and
Roaming AppData trees, including managed rollback backups. Protect the Windows
account and do not share those directories. Release scripts are not currently
Authenticode-signed; verify the SHA-256 published with each GitHub Release.

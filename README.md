# MannoCopy

A small macOS app that helps you run safe `rsync` synchronizations with a clear workflow:
**Plan (dry-run) → Confirm → Sync**, plus live progress, logs, and a Stop button.

> 🇩🇪 German documentation: **[README.de.md](README.de.md)**  
> The app UI is currently **German**.

---

## Features

- Manage multiple sync pairs (folder-to-folder or selected files)
- Always creates a **plan** first (dry-run)
- Confirmation dialog before the real sync starts
- Live progress (percentage / speed / ETA when available)
- Debug log view with copy-to-clipboard
- **Stop** button (terminates the running `rsync` process)

---

## Requirements

- macOS (Apple Silicon or Intel)
- `rsync` available on the system  
  - Uses system `rsync` or Homebrew `rsync` if installed

---

## How it works (high level)

1. Press **“Prüfen und Synchronisieren”** to generate a plan (dry-run)
2. Review the calculated file count / bytes
3. Confirm to start the real synchronization

---

## Safety notes

This tool can copy / overwrite files depending on your settings and `rsync` behavior.
Always double-check your source/target folders and keep backups.

---

## License

MIT — see **[LICENSE](LICENSE)**.

---

## Disclaimer

This software is provided **"as is"**, without warranty of any kind.
You are responsible for verifying your backup/sync configuration and results.

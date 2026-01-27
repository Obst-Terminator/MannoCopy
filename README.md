{\rtf1\ansi\ansicpg1252\cocoartf2867
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
{\colortbl;\red255\green255\blue255;}
{\*\expandedcolortbl;;}
\paperw11900\paperh16840\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\pard\tx720\tx1440\tx2160\tx2880\tx3600\tx4320\tx5040\tx5760\tx6480\tx7200\tx7920\tx8640\pardirnatural\partightenfactor0

\f0\fs24 \cf0 # MannoCopy\
\
A small macOS app that helps you run safe `rsync` synchronizations with a clear workflow:\
**Plan (dry-run) \uc0\u8594  Confirm \u8594  Sync**, plus live progress, logs, and a Stop button.\
\
> \uc0\u55356 \u56809 \u55356 \u56810  German documentation: **[README.de.md](README.de.md)**  \
> The app UI is currently **German**.\
\
---\
\
## Features\
\
- Manage multiple sync pairs (folder-to-folder or selected files)\
- Always creates a **plan** first (dry-run)\
- Confirmation dialog before the real sync starts\
- Live progress (percentage / speed / ETA when available)\
- Debug log view with copy-to-clipboard\
- **Stop** button (terminates the running `rsync` process)\
\
---\
\
## Requirements\
\
- macOS (Apple Silicon or Intel)\
- `rsync` available on the system  \
  - Uses system `rsync` or Homebrew `rsync` if installed\
\
---\
\
## How it works (high level)\
\
1. Press **\'93Pr\'fcfen und Synchronisieren\'94** to generate a plan (dry-run)\
2. Review the calculated file count / bytes\
3. Confirm to start the real synchronization\
\
---\
\
## Safety notes\
\
This tool can copy / overwrite files depending on your settings and `rsync` behavior.\
Always double-check your source/target folders and keep backups.\
\
---\
\
## License\
\
MIT \'97 see **[LICENSE](LICENSE)**.\
\
---\
\
## Disclaimer\
\
This software is provided **"as is"**, without warranty of any kind.\
You are responsible for verifying your backup/sync configuration and results.}
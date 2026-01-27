{\rtf1\ansi\ansicpg1252\cocoartf2867
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
{\colortbl;\red255\green255\blue255;}
{\*\expandedcolortbl;;}
\paperw11900\paperh16840\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\pard\tx720\tx1440\tx2160\tx2880\tx3600\tx4320\tx5040\tx5760\tx6480\tx7200\tx7920\tx8640\pardirnatural\partightenfactor0

\f0\fs24 \cf0 # MannoCopy\
\
Eine kleine macOS-App, die `rsync`-Synchronisationen mit einem klaren Ablauf sicherer macht:\
**Plan (Dry-Run) \uc0\u8594  Best\'e4tigen \u8594  Synchronisieren**, inkl. Live-Fortschritt, Debug-Log und Stopp-Button.\
\
> \uc0\u55356 \u56812 \u55356 \u56807  English documentation: **[README.md](README.md)**  \
> Die App-Oberfl\'e4che ist aktuell **Deutsch**.\
\
---\
\
## Funktionen\
\
- Mehrere Synchronisations-Paare verwalten (Ordner-Paar oder Dateiauswahl)\
- Erst **Plan erstellen** (Dry-Run)\
- Best\'e4tigungsdialog vor dem echten Sync\
- Live-Fortschritt (Prozent / Speed / ETA, wenn verf\'fcgbar)\
- Debug-Log mit Copy-Button\
- **Stopp**-Button (beendet den laufenden `rsync`-Prozess)\
\
---\
\
## Voraussetzungen\
\
- macOS (Apple Silicon oder Intel)\
- `rsync` auf dem System  \
  - Nutzt system-`rsync` oder Homebrew-`rsync` falls installiert\
\
---\
\
## Ablauf (kurz)\
\
1. **\'84Pr\'fcfen und Synchronisieren\'93** \uc0\u8594  erstellt einen Plan (Dry-Run)\
2. Datei-/Datenmenge pr\'fcfen\
3. Best\'e4tigen \uc0\u8594  Synchronisation starten\
\
---\
\
## Sicherheitshinweise\
\
Dieses Tool kann \'97 abh\'e4ngig von Einstellungen und `rsync`-Verhalten \'97 Dateien kopieren/\'fcberschreiben.\
Bitte Quelle/Ziel sorgf\'e4ltig pr\'fcfen und im Zweifel zus\'e4tzlich Backups machen.\
\
---\
\
## Lizenz\
\
MIT \'97 siehe **[LICENSE](LICENSE)**.\
\
---\
\
## Haftungsausschluss\
\
Die Software wird **\'84wie sie ist\'93** bereitgestellt, ohne Gew\'e4hrleistung.\
Du bist selbst verantwortlich, die Konfiguration und Ergebnisse zu pr\'fcfen.}
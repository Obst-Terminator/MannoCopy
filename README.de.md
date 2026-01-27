# MannoCopy

Eine kleine macOS-App, die `rsync`-Synchronisationen mit einem klaren Ablauf sicherer macht:
**Plan (Dry-Run) → Bestätigen → Synchronisieren**, inkl. Live-Fortschritt, Debug-Log und Stopp-Button.

> 🇬🇧 English documentation: **[README.md](README.md)**  
> Die App-Oberfläche ist aktuell **Deutsch**.

---

## Funktionen

- Mehrere Synchronisations-Paare verwalten (Ordner-Paar oder Dateiauswahl)
- Erst **Plan erstellen** (Dry-Run)
- Bestätigungsdialog vor dem echten Sync
- Live-Fortschritt (Prozent / Speed / ETA, wenn verfügbar)
- Debug-Log mit Copy-Button
- **Stopp**-Button (beendet den laufenden `rsync`-Prozess)

---

## Voraussetzungen

- macOS (Apple Silicon oder Intel)
- `rsync` auf dem System  
  - Nutzt system-`rsync` oder Homebrew-`rsync` falls installiert

---

## Ablauf (kurz)

1. **„Prüfen und Synchronisieren“** → erstellt einen Plan (Dry-Run)
2. Datei-/Datenmenge prüfen
3. Bestätigen → Synchronisation starten

---

## Sicherheitshinweise

Dieses Tool kann — abhängig von Einstellungen und `rsync`-Verhalten — Dateien kopieren/überschreiben.
Bitte Quelle/Ziel sorgfältig prüfen und im Zweifel zusätzlich Backups machen.

---

## Lizenz

MIT — siehe **[LICENSE](LICENSE)**.

---

## Haftungsausschluss

Die Software wird **„wie sie ist“** bereitgestellt, ohne Gewährleistung.
Du bist selbst verantwortlich, die Konfiguration und Ergebnisse zu prüfen.

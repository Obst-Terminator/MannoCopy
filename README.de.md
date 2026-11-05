# MannoCopy

Eine kleine macOS-App, die `rsync`-Synchronisationen mit einem klaren Ablauf sicherer macht:
**Plan (Dry-Run) → Bestätigen → Synchronisieren**, inkl. Live-Fortschritt, Debug-Log und Stopp-Button.

> 🇬🇧 English documentation: **[README.md](README.md)**  
> Die App-Oberfläche ist aktuell **Deutsch**.

Änderungen: **[Changelog](CHANGELOG.md)**

---

## Funktionen

- Mehrere Synchronisations-Paare verwalten (Ordner-Paar oder Dateiauswahl)
- Erst **Plan erstellen** (Dry-Run)
- Unveränderte Pläne sofort abschließen; nur geänderte Paare synchronisieren
- Bestätigungsdialog vor dem echten Sync
- Live-Fortschritt mit geglätteter Geschwindigkeits- und ETA-Anzeige
- Vergangene Arbeitszeit und wechselnde Katzensprüche von Louis / King Kong
- Klare Ablaufphasen (Planen / Bestätigen / Synchronisieren)
- **Sicherer Stopp**-Button (beendet laufende `rsync`-Prozesse sauber)
- Integrierte Update-Funktion (Sparkle)
- Debug-Log mit Copy-Button

---

## Voraussetzungen

- macOS (Apple Silicon oder Intel)
- `rsync` auf dem System  
  - Nutzt system-`rsync` oder Homebrew-`rsync` falls installiert

## Systemvoraussetzungen

- macOS **Sequoia (15.6)** oder neuer
- Xcode **26** oder neuer mit Swift **6.2** oder neuer (zum Bauen und für `swift test`)
- `rsync` auf dem System verfügbar
---

## Ablauf (kurz)

1. **„Prüfen und Synchronisieren“** → erstellt einen Plan (Dry-Run)
2. Datei-/Datenmenge prüfen
3. Bestätigen → Synchronisation starten

Ohne Änderungen endet der Lauf mit **„Alles aktuell, keine Synchronisation nötig.“** ohne zweiten Scan. Auch Änderungen an Ordnern, Links und Metadaten zählen als Änderungen.

---

## Sicherheitshinweise

Dieses Tool kann — abhängig von Einstellungen und `rsync`-Verhalten — Dateien kopieren/überschreiben.
Bitte Quelle/Ziel sorgfältig prüfen und im Zweifel zusätzlich Backups machen.

> Hinweis: Die Benutzeroberfläche ist aktuell **nur auf Deutsch** verfügbar.
---

## Lizenz

MIT — siehe **[LICENSE](LICENSE)**.

---

## Haftungsausschluss

Die Software wird **„wie sie ist“** bereitgestellt, ohne Gewährleistung.
Du bist selbst verantwortlich, die Konfiguration und Ergebnisse zu prüfen.

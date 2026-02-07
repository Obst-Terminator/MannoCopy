# MannoCopy – Fehlerbilder & Failure-Modes (Deutsch)

## Ziel
Dieses Dokument beschreibt typische Fehlerzustände, deren Ursachen
und das erwartete Verhalten der App.

---

## Exit-Codes

| Code | Bedeutung |
|----|-----------|
| 0 | Erfolg |
| 23 | Partial Transfer |
| 127 | Prozess konnte nicht gestartet werden |

---

## Häufige Fehlerfälle

### Exit-Code 23
**Ursachen**
- fehlender Vollzugriff auf Festplatte
- Rechteprobleme
- Dateien während des Laufs geändert

**App-Verhalten**
- Warnhinweis
- Verweis auf Systemeinstellungen

---

### Keine Fortschrittsanzeige
**Ursache**
- Apple rsync 2.6.9

**Lösung**
- Homebrew rsync installieren

---

### Abbruch blockiert Volumes
**Ursache**
- rsync noch aktiv

**Gegenmaßnahme**
- SIGKILL-Fallback

---

## Garantien

- kein rsync läuft unbeaufsichtigt
- Abbruch jederzeit möglich
- Debug-Log immer verfügbar

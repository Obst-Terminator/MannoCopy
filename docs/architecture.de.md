# MannoCopy – Architektur & Interna (Deutsch)

## Zweck dieses Dokuments
Dieses Dokument beschreibt die **interne Architektur, Zustandslogik und Ausführungssemantik**
von MannoCopy. Es richtet sich an Entwickler:innen und dient als Referenz für Wartung,
Erweiterung und Debugging.

---

## Architekturüberblick

MannoCopy folgt einem **Model-zentrierten Design**:

- `MannoCopyModel` ist **Single Source of Truth**
- UI (SwiftUI) bindet ausschließlich an Modellzustand
- rsync-Prozesse werden explizit verwaltet und kontrolliert

```
SwiftUI Views
      │
      ▼
MannoCopyModel  (@Observable)
      │
      ▼
Rsync-Orchestrierung
      │
      ▼
Process / Pipe (PosixSpawn)
```

---

## Zentrale Designprinzipien

- **Planbarkeit vor Ausführung** (immer Dry-Run)
- **Explizite Nutzerbestätigung**
- **Abbruchbarkeit jederzeit**
- **Keine stillen Fehler**
- **Thread-sichere Statusverwaltung**

---

## Zustandsmodell (RunPhase)

| Phase | Bedeutung |
|-----|-----------|
| idle | kein Lauf aktiv |
| checking | Dry-Run / Planung |
| awaitingConfirm | Plan fertig, wartet auf Nutzer |
| syncing | echte Synchronisation |

**Invarianten**
- syncing ohne vorherigen checking-Lauf nur bei explizitem Überspringen
- `isRunning == true` impliziert genau eine aktive Phase

---

## Prozessverwaltung

### Warum eigene Prozesslogik?
macOS beendet Child-Prozesse nicht automatisch beim App-Ende.
Daher verwaltet MannoCopy alle `rsync`-Prozesse explizit.

### Stop-Strategie
1. `SIGTERM`
2. 1 Sekunde warten
3. Fallback: `SIGKILL`

Der Abbruch ist **idempotent**.

---

## Dry-Run (Planung)

### Ziel
- Dateianzahl
- Gesamtgröße in Bytes
- ohne Daten zu verändern

### Technik
rsync mit:
- `--dry-run`
- `--out-format=%l\t%n`
- `--no-human-readable`

Ausgabe wird zeilenweise geparst.

---

## Großes Dataset – Heuristik

Schwellenwerte:
- ≥ 150.000 Dateien
- ≥ 500 GB

Bei Überschreitung:
- UI-Hinweis
- Option: Plan überspringen

---

## Fortschrittsberechnung

- rsync 3+: `--info=progress2`
- Fallback: Prozent aus `--progress`
- Geschwindigkeitsglättung über gleitenden Mittelwert

Dry-Run liefert Baseline für stabilere ETA.

---

## Datenschutz (macOS TCC)

Erkennung:
- Exit-Code 23
- typische Fehltexte

Verhalten:
- einmaliger Hinweisdialog
- Weiterleitung zu Systemeinstellungen

---

## Debug-Log

- append-only
- begrenzt auf 2 Mio Zeichen
- Auto-Öffnung bei Fehlern

---

## Wartungshinweise

**Gefährliche Bereiche**
- Process-Streaming
- Abbruchlogik
- Dry-Run Parsing

**Sichere Bereiche**
- UI
- Texte
- Sparkle-Integration

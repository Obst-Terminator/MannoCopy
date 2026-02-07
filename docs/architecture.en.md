# MannoCopy – Architecture & Internals (English)

## Purpose of this document
This document describes the **internal architecture, state machine and execution semantics**
of MannoCopy. It is intended for developers and serves as a long-term maintenance reference.

---

## Architecture Overview

MannoCopy follows a **model-centric design**:

- `MannoCopyModel` is the **single source of truth**
- SwiftUI binds exclusively to model state
- rsync processes are explicitly managed

```
SwiftUI Views
      │
      ▼
MannoCopyModel  (@Observable)
      │
      ▼
Rsync orchestration
      │
      ▼
Process / Pipe (PosixSpawn)
```

---

## Core Design Principles

- **Plan before execution** (always dry-run)
- **Explicit user confirmation**
- **Cancelable at any time**
- **No silent failures**
- **Thread-safe state handling**

---

## State Model (RunPhase)

| Phase | Meaning |
|-----|---------|
| idle | nothing running |
| checking | dry-run / planning |
| awaitingConfirm | waiting for user confirmation |
| syncing | real synchronization |

**Invariants**
- syncing without prior planning only via explicit skip
- `isRunning == true` implies exactly one active phase

---

## Process Management

### Why custom process handling?
macOS does not automatically terminate child processes when an app exits.
Therefore all `rsync` processes are tracked and controlled explicitly.

### Stop strategy
1. `SIGTERM`
2. wait 1 second
3. fallback: `SIGKILL`

Stop is **idempotent**.

---

## Dry-Run (Planning)

### Goal
- file count
- total bytes
- without modifying data

### Technique
rsync with:
- `--dry-run`
- `--out-format=%l\t%n`
- `--no-human-readable`

Output is parsed line by line.

---

## Large Dataset Heuristic

Thresholds:
- ≥ 150,000 files
- ≥ 500 GB

When exceeded:
- UI warning
- option to skip planning

---

## Progress Calculation

- rsync 3+: `--info=progress2`
- fallback: percentage from `--progress`
- speed smoothing via sliding window

Dry-run provides baseline for stable ETA.

---

## Privacy (macOS TCC)

Detection:
- exit code 23
- common permission error messages

Behavior:
- single warning dialog
- redirect to system settings

---

## Debug Log

- append-only
- capped at 2 million characters
- auto-expand on errors

---

## Maintenance Notes

**High-risk areas**
- process streaming
- cancellation logic
- dry-run parsing

**Low-risk areas**
- UI
- texts
- Sparkle integration

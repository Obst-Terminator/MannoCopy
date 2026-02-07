# MannoCopy – Failure Modes & Errors (English)

## Purpose
This document describes common error conditions, their causes,
and the expected application behavior.

---

## Exit Codes

| Code | Meaning |
|----|---------|
| 0 | Success |
| 23 | Partial transfer |
| 127 | Process could not be started |

---

## Common Failure Cases

### Exit Code 23
**Causes**
- missing Full Disk Access
- permission issues
- files changed during run

**App Behavior**
- warning dialog
- link to system settings

---

### No progress display
**Cause**
- Apple rsync 2.6.9

**Solution**
- install Homebrew rsync

---

### Cancel leaves volumes blocked
**Cause**
- rsync still running

**Mitigation**
- SIGKILL fallback

---

## Guarantees

- no unattended rsync processes
- cancellation always possible
- debug log always available

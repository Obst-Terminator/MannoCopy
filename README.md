# MannoCopy

MannoCopy is a macOS app for copying and updating folders and selected files with `rsync`, including mounted NAS shares.

**Check first. Synchronize only when changes are needed.**

[Deutsch](README.de.md) · [Download 1.1.5](https://github.com/Obst-Terminator/MannoCopy/releases/tag/v1.1.5) · [Changelog](CHANGELOG.md)

The app interface is available in German.

## Download and installation

The current release, **1.1.5 (build 7)**, is a universal app for **Apple Silicon and Intel**, requiring **macOS 15.6 or later**.

1. [Download MannoCopy-1.1.5.zip](https://github.com/Obst-Terminator/MannoCopy/releases/download/v1.1.5/MannoCopy-1.1.5.zip).
2. Extract the ZIP and copy `MannoCopy.app` to your Applications folder.
3. Launch the app. Existing installations can update through **“Nach Updates suchen…”** (Check for Updates).

**Xcode is not required** to run the downloaded app. The [release page](https://github.com/Obst-Terminator/MannoCopy/releases/tag/v1.1.5) includes release notes and a SHA-256 checksum.

**Signing:** Like the previous release, 1.1.5 is signed with Apple Development, but is not Developer ID signed or notarized. macOS may show a security message when opening it for the first time. The Sparkle update archive is additionally signed with the existing EdDSA key.

## rsync and ETA

**Homebrew-rsync** is preferred for overall progress and estimated remaining time for the current folder pair. With Homebrew already installed, install rsync using the following command ([Homebrew formula](https://formulae.brew.sh/formula/rsync)):

```sh
brew install rsync
```

MannoCopy looks for `/opt/homebrew/bin/rsync` first, then `/usr/local/bin/rsync`, and otherwise falls back to `/usr/bin/rsync`.

- **Homebrew-rsync:** Progress and smoothed ETA for the current pair, based on the complete plan and measured byte increments. ETA appears after a short measurement period.
- **System-rsync:** Progress for the current file; no overall ETA.
- Speed and ETA are hidden after five seconds without a progress update. ETA is an estimate, not a guarantee.

## Workflow

1. Choose **“Ordner-Paar hinzufügen”** (Add Folder Pair) or **“Dateiauswahl hinzufügen”** (Add File Selection), then select the source and destination. Selected files must share the same parent folder. Mount NAS shares in macOS before selecting them.
2. Start **“Prüfen und Synchronisieren”** (Check and Synchronize). The dry-run compares source and destination without modifying files.
3. **No changes:** The app displays **“Alles aktuell, keine Synchronisation nötig.”** (Everything is up to date; no synchronization needed). The run finishes without confirmation or a second rsync invocation.
4. **Changes found:** Review and confirm the plan. Only affected pairs are synchronized. New directories, symbolic links and metadata changes also count as changes, even if no regular file contents need copying.

For folder pairs, the source contents are copied into a subfolder with the source folder’s name at the chosen destination. If the chosen destination already has that name, it is used directly. The plan shows the actual source and destination paths.

The initial comparison can still take time on a NAS with many files: even unchanged files require metadata queries. An unchanged plan avoids the previously redundant second pass.

## Interface and controls

- Multiple saved copy jobs for folders or individual files.
- Separate metrics for transferred data, speed and remaining time for the current pair.
- **Elapsed work time** covering planning and transfer across all pairs. Confirmation time is excluded; the duration remains visible after completion or cancellation.
- **Louis and King Kong** keep you company with the original cat messages, rotating every three seconds while working.
- **Stop** cancels the current operation; a new run remains locked until cancellation finishes.
- Scrollable plan and debug area with auto-scroll and copy support. Logs contain diagnostics rather than every filename.
- Update checks through **Sparkle**.

## Photos libraries and archives

MannoCopy identifies Photos libraries from selected paths and existing rsync output, without an additional scan. **Close Photos before copying a library.** Full Disk Access may be required depending on macOS permissions. Detection does not guarantee database consistency. Selecting only subfolders such as `originals` does not back up the complete library.

For large plans, a notice offers **“Als Archiv sichern”** (Save as Archive). After planning stops, select a source and destination again. The app creates a `.tar` archive and a `.tar.sha256` checksum file directly at the destination. Size estimation, archiving and checksum calculation can be cancelled.

The large-plan notice also offers an explicit option to skip the remaining planning and synchronize immediately. No overall ETA is shown without a complete plan.

## Copy semantics

MannoCopy uses `rsync -a -u`: files can be added or overwritten, while newer destination files are skipped. Extra files at the destination are not automatically deleted. The result is therefore not an exact mirror or a guaranteed complete clone of macOS metadata.

Check source and destination carefully and retain independent backups. Overlapping source and destination folders, and archive destinations inside the source, are rejected.

## Development and tests

Building from source requires **Xcode 26 or later with Swift 6.2 or later**. Open `MannoCopy.xcodeproj`, select the `MannoCopy` scheme and configure signing for your own team. Sparkle is included as a Swift package dependency.

The standalone regression tests use Swift Testing:

```sh
swift test
```

The 12 tests cover plan parsing, changed-pair selection, metadata, links, directories, special filenames, progress and process cancellation. Copy checks use temporary files and locally available rsync implementations. They do not replace measurements on large NAS datasets or validation of real Photos databases. Build the app itself using the Xcode project.

Further details: [Changelog](CHANGELOG.md) · [Technical update notes (German)](docs/improvements-2026-11.de.md)

## License

[MIT](LICENSE). The software is provided without warranty. You are responsible for verifying your backup and synchronization configuration.

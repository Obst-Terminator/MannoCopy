# MannoCopy

MannoCopy ist eine macOS-App zum Kopieren und Aktualisieren von Ordnern und ausgewählten Dateien mit `rsync` – auch auf eingehängte NAS-Freigaben.

**Erst prüfen. Nur bei Änderungen synchronisieren.**

[English](README.md) · [Download 1.1.5](https://github.com/Obst-Terminator/MannoCopy/releases/tag/v1.1.5) · [Changelog](CHANGELOG.md)

Die App-Oberfläche ist auf Deutsch verfügbar.

## Download und Installation

Die aktuelle Version **1.1.5 (Build 7)** ist eine Universal-App für **Apple Silicon und Intel** und benötigt **macOS 15.6 oder neuer**.

1. [MannoCopy-1.1.5.zip herunterladen](https://github.com/Obst-Terminator/MannoCopy/releases/download/v1.1.5/MannoCopy-1.1.5.zip).
2. Das ZIP entpacken und `MannoCopy.app` in den Programme-Ordner kopieren.
3. Die App starten. Eine bestehende Installation kann über **„Nach Updates suchen…“** aktualisiert werden.

Zum Ausführen der fertigen App wird **kein Xcode** benötigt. Die [Release-Seite](https://github.com/Obst-Terminator/MannoCopy/releases/tag/v1.1.5) enthält die Änderungen und eine SHA-256-Prüfsumme.

**Signierung:** Wie die Vorversion ist 1.1.5 mit Apple Development signiert, aber nicht Developer-ID-signiert oder notarisiert. macOS kann beim ersten Öffnen eine Sicherheitsmeldung anzeigen. Das Sparkle-Update-Archiv ist zusätzlich mit dem bestehenden EdDSA-Schlüssel signiert.

## rsync und ETA

Für den Gesamtfortschritt des aktuellen Ordnerpaares und die Restzeitschätzung wird **Homebrew-rsync** bevorzugt. Bei bereits installiertem Homebrew lässt es sich mit folgendem Befehl installieren ([Homebrew-Formel](https://formulae.brew.sh/formula/rsync)):

```sh
brew install rsync
```

MannoCopy sucht zuerst unter `/opt/homebrew/bin/rsync`, danach unter `/usr/local/bin/rsync` und verwendet andernfalls `/usr/bin/rsync`.

- **Homebrew-rsync:** Fortschritt und geglättete ETA für das aktuelle Paar, basierend auf dem vollständigen Plan und gemessenen Byte-Zuwächsen. Die ETA erscheint erst nach einer kurzen Messphase.
- **System-rsync:** Fortschritt der aktuellen Datei; keine Gesamt-ETA.
- Nach fünf Sekunden ohne Fortschrittsmeldung werden Geschwindigkeit und ETA ausgeblendet. Die ETA ist eine Schätzung, keine Zusage.

## Ablauf

1. **„Ordner-Paar hinzufügen“** oder **„Dateiauswahl hinzufügen“** wählen und Quelle sowie Ziel festlegen. Ausgewählte Dateien müssen aus demselben Ordner stammen. Eine NAS-Freigabe muss zuvor in macOS eingebunden sein.
2. **„Prüfen und Synchronisieren“** starten. Der Dry-Run vergleicht Quelle und Ziel, ohne Dateien zu verändern.
3. **Keine Änderungen:** Die Meldung **„Alles aktuell, keine Synchronisation nötig.“** erscheint. Der Lauf endet ohne Bestätigung und ohne zweiten rsync-Aufruf.
4. **Änderungen vorhanden:** Plan prüfen und bestätigen. Nur betroffene Paare werden synchronisiert. Neue Ordner, symbolische Links und Metadatenänderungen zählen ebenfalls als Änderungen, auch wenn keine regulären Dateiinhalte kopiert werden müssen.

Bei Ordnerpaaren wird der Inhalt der Quelle in einen gleichnamigen Unterordner des gewählten Ziels kopiert. Hat das gewählte Ziel bereits denselben Ordnernamen, wird es direkt verwendet. Die tatsächlichen Quell- und Zielpfade stehen im Plan.

Ein erster Vergleich kann bei vielen Dateien auf einer NAS weiterhin dauern: Auch ein unveränderter Bestand erfordert Metadatenabfragen. Bei einem unveränderten Plan entfällt der bisherige zweite Durchlauf.

## Anzeige und Bedienung

- Mehrere gespeicherte Kopieraufträge für Ordner oder einzelne Dateien.
- Getrennte Anzeigen für übertragene Daten, Geschwindigkeit und Restzeit des aktuellen Paares.
- **Vergangene Arbeitszeit** über Prüfung und Übertragung aller Paare. Die Bestätigungszeit zählt nicht mit; nach Abschluss oder Abbruch bleibt die Dauer stehen.
- **Louis und King Kong** begleiten die Wartezeit mit den ursprünglichen Katzensprüchen, die alle drei Sekunden wechseln.
- **Stopp** beendet den laufenden Vorgang; ein neuer Lauf bleibt bis zum Abschluss des Abbruchs gesperrt.
- Scrollbarer Plan und Debug-Bereich mit Auto-Scroll und Kopierfunktion. Das Protokoll enthält Diagnosen, aber nicht sämtliche Dateinamen.
- Update-Suche über **Sparkle**.

## Fotos-Mediatheken und Archive

MannoCopy erkennt Fotos-Mediatheken anhand ausgewählter Pfade und vorhandener rsync-Ausgabe, ohne einen zusätzlichen Suchlauf durchzuführen. **Fotos vor dem Kopieren einer Mediathek schließen.** Je nach macOS-Berechtigungen kann Vollzugriff auf die Festplatte erforderlich sein. Die Erkennung garantiert keine Datenbankkonsistenz. Wer nur Unterordner wie `originals` auswählt, sichert damit nicht die vollständige Mediathek.

Bei großen Plänen erscheint ein Hinweis mit der Möglichkeit, **„Als Archiv sichern“** zu wählen. Nach dem Beenden der Prüfung werden Quelle und Ziel erneut ausgewählt. Die App erstellt ein `.tar`-Archiv und eine `.tar.sha256`-Prüfsummendatei direkt im Ziel. Größenprüfung, Archivierung und Prüfsummenberechnung sind abbrechbar.

Der Hinweis für große Pläne bietet außerdem eine ausdrückliche Option zum Überspringen der restlichen Planung und direkten Synchronisieren. Ohne vollständigen Plan wird keine Gesamt-ETA angezeigt.

## Kopierverhalten

MannoCopy verwendet `rsync -a -u`: Dateien können hinzugefügt oder überschrieben werden; neuere Zieldateien werden übersprungen. Zusätzliche Dateien im Ziel werden nicht automatisch gelöscht. Das Ergebnis ist daher kein exakter Spiegel und kein zugesicherter vollständiger macOS-Metadaten-Klon.

Quelle und Ziel sorgfältig prüfen und unabhängige Backups behalten. Überlappende Quell- und Zielordner sowie Archivziele innerhalb der Quelle werden zurückgewiesen.

## Entwicklung und Tests

Zum Bauen aus dem Quellcode: **Xcode 26 oder neuer mit Swift 6.2 oder neuer**. `MannoCopy.xcodeproj` öffnen, das Schema `MannoCopy` wählen und die Signierung für das eigene Team konfigurieren. Sparkle wird als Swift-Package-Abhängigkeit eingebunden.

Die separaten Regressionstests verwenden Swift Testing:

```sh
swift test
```

Die 12 Tests prüfen unter anderem Plan-Auswertung, Auswahl geänderter Paare, Metadaten, Links, Ordner, Sonderzeichen, Fortschritt und Prozessabbruch. Kopiertests verwenden temporäre Dateien und die lokal vorhandenen rsync-Varianten. Sie ersetzen keine Messung großer NAS-Bestände oder Prüfung echter Fotos-Datenbanken. Die App selbst wird mit dem Xcode-Projekt gebaut.

Weitere Details: [Changelog](CHANGELOG.md) · [Technische Überarbeitung](docs/improvements-2026-11.de.md)

## Lizenz

[MIT](LICENSE). Die Software wird ohne Gewährleistung bereitgestellt. Du bist für die Prüfung deiner Sicherungs- und Synchronisationskonfiguration verantwortlich.

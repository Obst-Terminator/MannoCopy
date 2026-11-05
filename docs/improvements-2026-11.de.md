# Überarbeitung November 2026

Die vollständige Änderungsliste steht im [Changelog für 1.1.5](../CHANGELOG.md).

- Ein unveränderter Plan beendet den Lauf ohne zweiten rsync-Aufruf. Bei Änderungen werden nur betroffene Paare synchronisiert; Ordner, Links und Metadaten werden berücksichtigt.
- Die vergangene Arbeitszeit bleibt nach Abschluss sichtbar und pausiert während der Bestätigung. Die ursprünglichen Katzensprüche wechseln während der Arbeit alle drei Sekunden.

- Homebrew-rsync bleibt bevorzugt (`/opt/homebrew/bin/rsync`, danach `/usr/local/bin/rsync`). System-rsync dient als Fallback.
- Die ETA für das aktuelle Paar nutzt die geplante Datenmenge und Byte-Zuwächse über ein Zeitfenster von ungefähr zehn Sekunden. Sie erscheint nach mindestens drei Sekunden Messung. Nach fünf Sekunden ohne Fortschrittsmeldung werden Geschwindigkeit und ETA ausgeblendet. Ohne vollständigen Plan wird keine Gesamt-ETA angegeben.
- System-rsync zeigt ausdrücklich den Fortschritt der aktuellen Datei. Seine Prozentanzeige wird nicht als Gesamtfortschritt verwendet.
- Die Planung bündelt Anzeige-Updates auf höchstens fünf pro Sekunde plus Schlussstand. Einzelne Dateinamen werden nicht mehr vollständig ins Debug-Protokoll geschrieben. Ordnerpaare werden nacheinander geprüft, um konkurrierende Zugriffe auf HDDs und Netzwerkfreigaben zu vermeiden.
- Dateiauswahlen verwenden explizite Dateipfade. Dadurch müssen unbeteiligte Unterordner nicht durchsucht werden; Zeichen wie `*` und `[` bleiben Bestandteile des Dateinamens.
- Fotos-Mediatheken werden anhand ausgewählter Pfade und ohnehin vorhandener rsync-Ausgabe erkannt. Es gibt keinen zusätzlichen Suchlauf. Der Hinweis vor dem Kopieren erinnert daran, Fotos zu schließen. Das ersetzt keine Prüfung der Datenbankkonsistenz.
- Fehlgeschlagene Prüfläufe führen nicht zur Synchronisationsbestätigung. Nach Stopp bleibt der Lauf gesperrt, bis die Worker beendet sind. Größenprüfung und Prüfsummenberechnung der vorhandenen Archivfunktion sind ebenfalls abbrechbar.
- Fortschrittsparser und Prozessausführung liegen in `MannoCopy/TransferCore.swift`; die Oberfläche bietet getrennte Kennzahlen und einen scrollbareren Detailbereich.

## Prüfung

Die unabhängigen Swift-Testing-Regressionstests lassen sich im Projektordner mit `swift test` ausführen. Sie verwenden temporäre Beispieldateien und prüfen unter anderem beide installierten rsync-Varianten, Sonderzeichen, einen unveränderten zweiten Lauf, eine künstliche Mediathek, Prozessabbruch und aufgeteilte UTF-8-Ausgabe. Die App wird weiterhin mit dem Xcode-Projekt gebaut.

Nicht abgedeckt sind echte Fotos-Datenbanken, große HDD-/SMB-Datenbestände und eine visuelle Laufzeitprüfung des macOS-Fensters. Deshalb gibt es keine gemessene Aussage zur Beschleunigung auf solchen Datenträgern. `rsync -a -u` bleibt unverändert die Kopiersemantik: neuere Zieldateien werden übersprungen; es wird kein vollständiger macOS-Metadaten-Klon zugesichert.

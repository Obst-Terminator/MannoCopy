# Changelog

## 1.1.5 — 2026-11-05

### Deutsch

#### Prüfung und Synchronisation

- Die Prüfung bleibt der erste Schritt. Sind alle Paare unverändert, endet der Lauf mit **„Alles aktuell, keine Synchronisation nötig.“** — ohne Bestätigungsdialog und ohne zweiten rsync-Aufruf.
- Nach Bestätigung werden nur Ordnerpaare mit Änderungen synchronisiert. Neue Verzeichnisse, symbolische Links und Metadatenänderungen werden zusätzlich zu regulären Dateiübertragungen erkannt und im Plan berücksichtigt.
- Fehlgeschlagene oder abgebrochene Prüfungen werden nicht als vollständiger Plan angeboten. Änderungen an der Auftragsliste machen einen vorbereiteten Plan ungültig.
- Dateiauswahlen verwenden explizite Pfade statt Include-Muster: Unbeteiligte Unterordner müssen nicht durchsucht werden, und Sonderzeichen wie `*` und `[` bleiben wörtliche Bestandteile der Dateinamen.
- Die Planung bündelt UI-Aktualisierungen und verzichtet auf das vollständige Protokollieren aller Dateinamen. Ordnerpaare werden nacheinander geprüft, um konkurrierende Zugriffe auf HDDs und NAS-Freigaben zu vermeiden.

#### Fortschritt und Oberfläche

- Homebrew-rsync bleibt bevorzugt. Seine ETA wird pro aktuellem Paar aus der geplanten Datenmenge und tatsächlichen Byte-Zuwächsen über ein Zeitfenster berechnet.
- Die ETA erscheint nach einer kurzen Messphase; ohne vollständigen Plan wird keine Gesamt-ETA angegeben. Geschwindigkeit und ETA werden nach fünf Sekunden ohne Fortschrittsmeldung ausgeblendet.
- Die tatsächlichen rsync-Dateizähler ersetzen Schätzungen anhand der übertragenen Datenmenge. Abschlussmeldungen erscheinen erst nach Prozessende.
- System-rsync dient als Fallback und zeigt ausdrücklich den Fortschritt der aktuellen Datei, ohne eine Gesamt-ETA vorzutäuschen.
- Ein Zeitzähler zeigt die Arbeitszeit für Prüfung und Übertragung über alle Paare. Während der Bestätigung pausiert er; nach Abschluss oder Abbruch bleibt die Dauer stehen.
- Alle ursprünglichen Katzensprüche von Louis und King Kong sind erhalten und wechseln während der Arbeit alle drei Sekunden.
- Überarbeitete Kopfzeile, aussagekräftigere Auftragsnamen, Leerzustand, getrennte Fortschrittskennzahlen, scrollbarere Details, kleinere Mindestfensterhöhe und besser erreichbare Update-Suche.

#### Mediatheken, Archivierung und Fehlerbehandlung

- Fotos-Mediatheken werden anhand ausgewählter Pfade und bereits vorhandener rsync-Ausgabe erkannt, ohne zusätzlichen rekursiven Suchlauf. Vor der Synchronisation wird an das Schließen von Fotos erinnert.
- Archivierung als `.tar` mit SHA-256-Datei direkt im gewählten Ziel ergänzt. Größenprüfung, Archivierung und Prüfsummenberechnung sind in die Abbruchverwaltung eingebunden.
- Nach Stopp bleibt der Lauf gesperrt, bis die Worker beendet sind. Ein Wechsel von der Planung zur Archivierung wartet auf das Ende der Prüfung statt auf eine feste Verzögerung.
- Überlappende Quell- und Zielpfade werden zurückgewiesen; ein Archivziel innerhalb der Quelle ist nicht erlaubt. Archivnamen erhalten Zeitstempel und eine eindeutige Ergänzung.
- Prozessausgaben werden über einen einzelnen Pipe-Leser verarbeitet. Aufgeteilte UTF-8-Zeichen, Wagenrückläufe und abschließende Ausgabereste werden berücksichtigt.
- Kompatibilitätskorrekturen für System-rsync/openrsync und Homebrew-rsync, einschließlich Byte-Suffixen und Ausgabeformaten. Ungültige UTF-8-Sequenzen verwerfen nicht mehr die komplette Ausgabe.

#### Entwicklung und Validierung

- Datenmodelle, rsync-Argumente, Parser und Prozessbausteine nach `TransferCore.swift` ausgelagert; unnötige Combine-Abhängigkeit entfernt und Modellbesitz in SwiftUI korrigiert.
- Separates Swift-Package für **12 Swift-Testing-Regressionstests** ergänzt (`swift test`). Abgedeckt sind unter anderem unveränderte Pläne, Auswahl geänderter Paare, Ordner/Links/Rechte, Sonderzeichen, Fortschrittsparser, Prozessabbruch und eine künstliche Mediathek.
- Xcode-Projekteinstellungen aktualisiert und App-Version auf 1.1.5 gesetzt. App-Build und alle 12 Tests erfolgreich geprüft.
- Keine gemessene Beschleunigungszusage für große NAS-/HDD-Bestände. Die künstliche Mediathek ersetzt keine Prüfung einer echten Fotos-Datenbank. Die bestehende Kopiersemantik `rsync -a -u` bleibt erhalten.

### English

- Keep the initial dry-run. An unchanged plan now finishes immediately with “Alles aktuell, keine Synchronisation nötig.”, without confirmation or a second rsync invocation.
- Synchronize only changed pairs after confirmation; include directory, symlink and metadata changes in the decision. Failed or cancelled plans cannot start a prepared sync.
- Use explicit paths for selected files, batch planning UI updates, reduce filename logging and serialize scans to avoid competing disk/network access.
- Prefer Homebrew-rsync; calculate per-pair ETA from planned bytes and measured byte increments, with a warm-up period and stale-progress handling. Use real file counters. System-rsync explicitly reports per-file progress without a whole-run ETA.
- Add an elapsed-work timer that pauses during confirmation and retains the final duration. Preserve all original Louis and King Kong cat messages, rotating every three seconds while working.
- Improve the header, pair labels, empty state, progress metrics, scrolling, minimum window height and update-check placement.
- Detect Photos libraries without an additional recursive scan and remind users to close Photos. Add target-side tar/SHA-256 archiving with managed cancellation, unique archive names and source/target overlap checks.
- Keep runs locked during cancellation, wait for planning to finish before archiving, and improve process streaming, UTF-8 handling and compatibility with system/openrsync and Homebrew-rsync output.
- Extract `TransferCore.swift`, remove the unnecessary Combine dependency, correct SwiftUI model ownership, update Xcode settings and set version 1.1.5.
- Add a standalone Swift package with 12 passing regression tests. The Xcode app build also passes. Large NAS/HDD performance and real Photos database consistency are not certified by these tests; `rsync -a -u` semantics remain unchanged.

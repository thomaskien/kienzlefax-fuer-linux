# KienzleFax reversibel verwalten

IMMER verwenden wenn einzelne KienzleFax-Funktionen auf einem bestehenden Gerät
pausiert oder wieder freigegeben werden sollen.

**Werkzeug:** `kienzlefax-verwalten.sh` · **Version:** 0.1.0 · **Stand:** 29.09.2026

Der separate Terminal-Assistent verändert die bestehende Installation gezielt.
Dokumente, wartende Faxe, Benutzer, Zugangsdaten und installierte Pakete bleiben
erhalten. Er lädt keine weiteren Skripte nach und startet keinen Installer.

## Herunterladen und starten

Auf dem **betroffenen Linux-Gerät** in einem eigenen Arbeitsverzeichnis:

```bash
curl -fL https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax-verwalten.sh -o kienzlefax-verwalten.sh
sudo bash kienzlefax-verwalten.sh
```

Den Startbefehl erst nach einem erfolgreichen Download ausführen. Python 3 und die
jeweiligen Werkzeuge der vorhandenen KienzleFax-Installation werden benötigt.
Für das sichere Anhalten laufender Worker/OCR-Dienste ist systemd mit cgroup v2
erforderlich; ohne diese Unterstützung verweigert der Assistent deren Stopp.
Es werden keine fehlenden Pakete automatisch installiert.

Weitere Aufrufe:

```bash
# Zustand anzeigen; schreibt keine Verwaltungsdateien
sudo bash kienzlefax-verwalten.sh --status

# Alle Fragen durchgehen und den Plan prüfen; keine Änderungen anwenden
sudo bash kienzlefax-verwalten.sh --dry-run

# Letzte Änderung oder unterbrochene Transaktion zurücknehmen
sudo bash kienzlefax-verwalten.sh --restore
```

`--help` und `--version` funktionieren auch ohne root und auf dem Entwicklungsrechner.
`--status` liefert Exit-Code 2 bei erkannten Abweichungen oder einer offenen
Transaktion, sonst 0. Fehler und Abbrüche liefern Exit-Code 1.

## Auswahl im Assistenten

Nur vorhandene Komponenten werden angeboten. Jede Frage hat den Standard
**unverändert**. Am Ende stehen eine Vorschau und eine gesonderte Bestätigung.
Ein Eingabeabbruch vor der Bestätigung verändert keine Konfigurationen oder Dienste.

| Bereich | Wirkung von „deaktivieren“ |
| --- | --- |
| Faxversand | Pausiert den Faxworker und verhindert dessen erneuten Start durch systemd. Wartende Aufträge bleiben erhalten. |
| Faxempfang | Sperrt neue Anrufe im Faxeingang vor `Answer()` mit `Hangup(17)`. Telefonie kann weiterlaufen. |
| Telefonie/Warteschlange | Sperrt die Telefonieeinstiege und entfernt die Telefonie-Endpunkte und -Registrierungen aus der geladenen PJSIP-Konfiguration. Gemeinsame Transporte und Fax bleiben erhalten. |
| Webinterface | Sperrt ausschließlich KienzleFax per Apache-Konfiguration, einschließlich der API-Aufrufe und zusätzlicher Pfadteile. Apache und andere Websites laufen weiter. |
| Scanner-OCR | Pausiert `scan-ocr.service`. Dies ist unabhängig von den Scan-Freigaben und der Fax-OCR. |
| Fax-OCR | Pausiert `scan-ocr-fax.service`. Nur zulässig, wenn auch Faxempfang deaktiviert ist. |
| Netzwerkfreigaben | Schaltet jede erkannte KienzleFax-Freigabe einzeln mit `available = no` ab. Samba und fremde Freigaben laufen weiter. |
| Faxdrucker | Stoppt jeden ausgewählten Drucker und lehnt neue Aufträge ab. Drucker werden anhand des KienzleFax-Backends erkannt und nicht gelöscht. |

Einzeln auswählbar sind die vorhandenen Freigaben `hierhin-scannen-fuer-ocr`,
`scan-eingang`, `fax-eingang`, `sendeberichte`, `sendefehler-eingang`,
`sendefehler-berichte` sowie `pdf-zu-fax` beziehungsweise `pdf-zu-faxN`.

Wenn **Faxversand und Faxempfang gemeinsam aus** sind, wird zusätzlich die
Fax-Providerregistrierung aus der aktiven Konfiguration entfernt und abgemeldet.
Bei einer nur einseitigen Faxpause bleibt sie für die andere Richtung bestehen.
Eine providerseitige Abmeldung kann verzögert wirksam werden; vor einem Umzug
auf ein anderes Gerät den Registrierungsstatus beim Provider prüfen.

### Beispiel: Fax abschalten, Scannen behalten

- Faxversand, Faxempfang, Webinterface und Faxdrucker deaktivieren.
- Die nicht mehr benötigten Fax-/Berichts-/PDF-zu-Fax-Freigaben einzeln deaktivieren.
- Scanner-OCR, `hierhin-scannen-fuer-ocr` und `scan-eingang` unverändert lassen.
- Fax-OCR kann ebenfalls pausiert werden, sobald deren Eingang abgearbeitet ist.
- Telefonie nach Bedarf weiterbetreiben oder separat deaktivieren.

Eine Freigabesperre betrifft **nur den Netzwerkzugriff**. Sie löscht keine Ordner
und verhindert keinen lokalen Zugriff. Vorhandene Dokumente können bei weiterhin
aktivem Webinterface dort sichtbar bleiben. `sources.json` wird nicht verändert.
Eine Websperre stoppt keinen Faxversand. Ein pausierter Worker verhindert nicht,
dass über ein weiterlaufendes Webinterface zusätzliche Sendeaufträge angelegt werden.

## Wieder aktivieren und Änderungen zurücknehmen

Erneut starten und bei den gewünschten Bereichen **„a – Sperre aufheben“** wählen.
Der Assistent stellt deren vorherigen Zustand wieder her. Bereits vor der Pause
gestoppte Dienste bleiben gestoppt; ursprüngliche Autostart- und Druckerflags
werden nicht pauschal auf „ein“ gesetzt. Extern abgeschaltete Komponenten ohne
eine gespeicherte Assistentenpause werden durch „a“ nicht eigenmächtig gestartet.

Auch einzelne Bereiche einer größeren Abschaltung lassen sich wieder freigeben.
Andere, weiterhin gewählte Sperren in gemeinsam verwendeten Dateien bleiben bestehen.
Vor dem Wiederanlaufen des Faxworkers fragt der Assistent bei wartenden Aufträgen
zusätzlich nach einer ausdrücklichen Versandfreigabe. OCR kann nach dem Aufheben
der Pause neu eingegangene Dateien weiterverarbeiten.

`--restore` nimmt die **letzte Transaktion als Ganzes** zurück. Die Funktion ist
kein beliebiges Zurückspringen durch die gesamte Historie. Auch eine unterbrochene
Wiederherstellung wird protokolliert und kann erneut mit `--restore` versucht werden.

## Schutzmaßnahmen und Grenzen

- Vor relevanten Änderungen werden aktive Telefonate/Faxe geprüft. Asterisk wird
  nicht neu gestartet. Die Faxsperre ersetzt nur den ersten Dialplanschritt;
  nachfolgende Schritte bleiben erhalten.
- Vor dem Stoppen eines laufenden OCR-Dienstes müssen Eingang und Arbeitsverzeichnis
  leer sein. Beim Faxworker darf keine Verarbeitung laufen. Die Dienste werden
  für die abschließende Prüfung kurz eingefroren und bei Abbruch wieder freigegeben.
- Offene Verbindungen zu ausgewählten Samba-Freigaben sowie noch nicht abgeschlossene
  Druckaufträge verhindern eine Änderung. Am Client zuerst die Verbindung trennen
  beziehungsweise die Druckverarbeitung abschließen lassen.
- Samba wird mit `testparm` geprüft; Abschaltungen werden zusätzlich durch einen
  lokalen `smbclient`-Zugriff kontrolliert. Die Websperre wird bei laufendem Apache
  auf HTTP und HTTPS auf Antwort 403 geprüft. Andere Webserver oder individuelle
  VirtualHosts sind kein automatisch unterstütztes Ziel.
- Laufende Asterisk-Konfigurationen werden nachgeladen und die gesperrten
  Dialplaneinstiege, entfernten Telefonie-Endpunkte und SIP-Registrierungen geprüft.
  Bei vorher gestoppten Diensten kann nur die persistente Konfiguration geändert
  werden; deren tatsächliche Laufzeitwirkung ist beim nächsten Start zu prüfen.
- Manuelle/ungewöhnliche PJSIP-Konfigurationen, zusätzliche Registrierungen in
  `pjsip.conf`, komplexe Dialplan-Includes sowie Samba-Includes/Registry-Konfiguration
  werden konservativ abgelehnt. Dafür werden keine Konfigurationen geraten.
- **Installerläufe berücksichtigen diese Verwaltung noch nicht.** Sie können
  Dateien neu schreiben oder Dienste aktivieren. Danach `--status` ausführen.
  Erkannte Änderungen an verwalteten Dateien verhindern automatisches Überschreiben
  und Wiederherstellen. Das gilt auch für legitime manuelle Änderungen: diese müssen
  anhand der Sicherung bewusst zusammengeführt werden.

Status und Sicherungen liegen unter `/var/lib/kienzlefax-verwalten/` mit
Verzeichnisrechten `0700` und Zustandsdateien `0600`. `state.json` hält die aktiven
Sperren und Originale, `pending.json` eine offene Transaktion, `last.json` die letzte
Transaktion; `history/` enthält die Historie. Konfigurationsinhalte sind im JSON
Base64-codiert gespeichert, **nicht verschlüsselt**. Die Sicherungen können
Zugangsdaten enthalten und dürfen nicht öffentlich geteilt werden. Der Assistent
gibt diese Inhalte nicht aus.

Bei einem Fehler versucht er die Rücknahme. Ist diese wegen neuer Arbeit oder
externer Änderungen nicht sicher möglich, bleibt die geschützte Transaktion erhalten
und der Assistent meldet ausdrücklich eine unvollständige Rücknahme. Dann die genannte
Ursache beheben und `--restore` erneut ausführen; nicht durch einen Installerlauf
über die Situation hinwegschreiben.

## Prüfung dieser Version

Automatisierte Tests laufen in isolierten Fake-Systemen ohne Zugriff auf echte
Dienste. Sie prüfen unter anderem Teilreaktivierung, exakte Dateiwiederherstellung,
ursprüngliche Dienst-/Druckerzustände, laufende Arbeit, Änderungen nach der Vorschau,
fremde Konfigurationsänderungen, Fehler beim Reload und Wiederaufnahme unterbrochener
Transaktionen. Zusätzlich werden die Shellsyntax und die eingebettete Python-Syntax geprüft.
Ein Live-Test auf einem Debian-/Raspberry-Pi-Gerät ist damit nicht ersetzt.

```bash
bash -n kienzlefax-verwalten.sh
bash kienzlefax-verwalten.sh --help
python3 -m unittest discover -s tests -p 'test_verwalten.py' -v
git diff --check
```

Technische Referenzen:
[systemd freeze/thaw](https://manpages.debian.org/trixie/systemd/systemctl.1.en.html),
[Asterisk-Registrierungen](https://docs.asterisk.org/Configuration/Channel-Drivers/SIP/Configuring-res_pjsip/Configuring-Outbound-Registrations/),
[Samba-Steuerung](https://www.samba.org/samba/docs/current/man-html/smbcontrol.1.html),
[CUPS-Druckersteuerung](https://www.cups.org/doc/man-cupsenable.html).

## Changelog

- **0.1.0 – 29.09.2026:** Erster separater Verwaltungsassistent mit einzeln wählbaren
  Bereichen, Vorschau, geschützten Sicherungen, Abweichungserkennung und Rücknahme.

# KienzleFax reversibel verwalten

IMMER verwenden wenn einzelne KienzleFax-Funktionen auf einem bestehenden Gerät
pausiert oder wieder freigegeben werden sollen.

**Werkzeug:** `kienzlefax-verwalten.sh` · **Version:** 0.2.0 · **Stand:** 29.09.2026

**Auswählen → sichern und speichern → neu starten.** Der Assistent setzt die
Konfiguration für den nächsten Neustart. Dokumente, Faxwarteschlangen, Benutzer,
Zugangsdaten und Pakete bleiben erhalten.

## Herunterladen und starten

```bash
curl -fL https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax-verwalten.sh -o kienzlefax-verwalten.sh
sudo bash kienzlefax-verwalten.sh
sudo reboot
```

Nur nach erfolgreichem Speichern neu starten. Der Assistent führt selbst keinen
Neustart aus. Bis dahin können die Dienste mit ihrer bisherigen Konfiguration
weiterlaufen. Webdatei und Druckereinstellungen werden bereits beim Speichern
angepasst. Aktive Gespräche und Arbeiten vor dem Neustart abschließen lassen.

Python 3 und die Werkzeuge der vorhandenen Installation werden benötigt. Der
Assistent lädt keine Module nach und installiert keine Pakete.

## Auswahl

Jeder Bereich wird einzeln abgefragt: **u** unverändert, **a** Sperre aufheben,
**d** deaktivieren. Standard ist unverändert. Vor dem Speichern erscheinen eine
Vorschau und eine Bestätigung.

| Bereich | Gespeicherte Änderung |
| --- | --- |
| Faxversand | systemd-Sperre für `kienzlefax-worker.service`; nach dem Neustart läuft der Worker nicht. |
| Faxempfang | Fax-Dialplaneinstiege weisen Anrufe vor dem Annehmen ab. |
| Telefonie/Warteschlange | Telefonie-Dialplaneinstiege werden gesperrt, zugehörige PJSIP-Endpunkte und Registrierungen aus der Konfiguration entfernt. |
| Webinterface | `/var/www/html/kienzlefax.php` geschützt sichern und entfernen. Aktivieren stellt Inhalt, Besitzer und Rechte wieder her. |
| Scanner-OCR | systemd-Sperre für `scan-ocr.service`, unabhängig von den Scan-Freigaben. |
| Fax-OCR | systemd-Sperre für `scan-ocr-fax.service`; nur zusammen mit deaktiviertem Faxempfang. |
| Netzwerkfreigaben | Jede ausgewählte KienzleFax-Freigabe erhält `available = no`. |
| Faxdrucker | Jeder ausgewählte Faxdrucker wird über CUPS angehalten und nimmt keine neuen Aufträge an. Die Einstellungen bleiben über den Neustart erhalten. |

Die Dienstsperren sind zusätzliche systemd-Dateien. Beim Aktivieren werden sie
wieder entfernt; die bisherigen Autostarteinstellungen bleiben erhalten. Ein vor
der Änderung nur manuell gestoppter, aber für den Autostart aktivierter Dienst
kann nach dem Neustart wieder laufen.

Sind Faxversand und Faxempfang gemeinsam deaktiviert, wird auch die
Fax-Providerregistrierung aus der Konfiguration entfernt. Der Assistent führt
keine Live-Abmeldung beim Provider aus. Vor einem Gerätewechsel nach dem Neustart
prüfen, dass das alte Gerät nicht mehr registriert ist.

Einzelne Freigaben: `hierhin-scannen-fuer-ocr`, `scan-eingang`, `fax-eingang`,
`sendeberichte`, `sendefehler-eingang`, `sendefehler-berichte` und
`pdf-zu-fax` beziehungsweise `pdf-zu-faxN`. Fremdfreigaben, fremde Drucker und
wiederholte Samba-`[global]`-Abschnitte bleiben erhalten.

Zum Abschalten von Fax bei weiter nutzbarem Scannen: Faxversand, Faxempfang,
Fax-OCR, Webinterface, Faxdrucker und Faxfreigaben deaktivieren. Scanner-OCR,
`hierhin-scannen-fuer-ocr` und `scan-eingang` unverändert lassen. Telefonie separat
wählen. Freigabesperren löschen keine Ordner; `sources.json` bleibt unverändert.

## Wieder aktivieren oder zurücknehmen

Für einzelne Bereiche den Assistenten erneut starten, **a** wählen und danach
neu starten. Die letzte Änderung als Ganzes wird so zurückgenommen:

```bash
sudo bash kienzlefax-verwalten.sh --restore
sudo reboot
```

Auch **offene Transaktionen aus Version 0.1.x** können mit `--restore`
zurückgeschrieben werden. Ein eingefrorener oder neu startender Dienst verhindert
das nicht. Soll anschließend eine andere Auswahl gelten, erst `--restore`, dann
den Assistenten erneut ausführen und zum Schluss einmal neu starten.

Beim Freigeben des Faxversands mit wartenden Aufträgen fragt der Assistent nach,
ob deren Versand beim nächsten Start erlaubt ist.

Weitere Aufrufe:

```bash
sudo bash kienzlefax-verwalten.sh --status
sudo bash kienzlefax-verwalten.sh --dry-run
```

`--status` zeigt die gespeicherte Auswahl und den momentanen Dienststatus.
Laufende Dienste gelten vor dem Neustart nicht als Konfigurationsfehler.
`--dry-run` zeigt nur den Dialog und die Vorschau. `--help` und `--version`
funktionieren ohne root. Erkannte Abweichungen/offene Transaktionen liefern bei
`--status` Exit-Code 2, sonst 0; Fehler und Abbrüche liefern Exit-Code 1.

## Sicherungen und Grenzen

Die geschützten Sicherungen liegen unter `/var/lib/kienzlefax-verwalten/`:
Verzeichnisse `0700`, Zustandsdateien `0600`. `state.json` hält Originale und
Auswahl, `pending.json` eine offene Transaktion, `last.json` die letzte Änderung,
`history/` die Historie. Die Dateien enthalten Base64-codierte Konfigurationen,
**keine Verschlüsselung**. Sie können Zugangsdaten enthalten und dürfen nicht
öffentlich geteilt werden. Im Webroot wird keine PHP-Sicherung abgelegt.

Extern geänderte Dateien werden nicht überschrieben. Das gilt auch für eine nach
der Pause neu angelegte `kienzlefax.php`. Bei einem Schreibfehler versucht der
Assistent, die vorherige Konfiguration zurückzuschreiben; bei unvollständiger
Rücknahme bleibt die Sicherung für `--restore` erhalten.

Samba-Konfigurationen werden vor dem Schreiben mit `testparm` geprüft. Individuelle
PJSIP-/Dialplan-Konfigurationen oder Samba-Includes werden weiterhin konservativ
behandelt. Der bekannte Telefonie-Datei-Include des Installers wird unterstützt.
Druckeränderungen setzen eine leere Druckwarteschlange voraus und löschen keine
Aufträge. Dienststart/-stopp, Freeze/Thaw, Asterisk-Reloads sowie lokale HTTP-/SMB-
Zugriffsprüfungen gehören nicht mehr zum Ablauf.

Installerläufe können verwaltete Dateien erneut ändern. Danach `--status` nutzen.
Die tatsächliche Wirkung auf dem Gerät ist nach dessen Neustart zu kontrollieren.

## Prüfung

Die automatisierten Prüfungen verwenden isolierte Dateien und simulierte
Systembefehle. Sie decken insbesondere Sicherung, Schreibfehler, Wiederherstellung,
fremde Änderungen und alte offene Transaktionen ab. Sie ersetzen keinen Neustart
des Zielgeräts.

```bash
bash -n kienzlefax-verwalten.sh
python3 -m unittest discover -s tests -p 'test_verwalten.py'
git diff --check
```

## Changelog

- **0.2.0 – 29.09.2026:** Vereinfachter Ablauf für den nächsten Neustart: Auswahl
  sichern und Konfiguration schreiben. Live-Dienststeuerung, Freeze/Thaw und
  Laufzeit-Reloads entfallen. Alte offene Transaktionen bleiben rücknehmbar,
  auch bei eingefrorenen Diensten. Fehler nennen die betroffene systemctl-Aktion.

- **0.1.4 – 29.09.2026:** Kurze systemd-Start-/Stoppübergänge führen nicht mehr sofort
  zum Abbruch. Die Statusprüfung wartet begrenzt und nennt bei dauerhaftem Übergang
  den Haupt- und Unterstatus. Das Freigeben eingefrorener Dienste bleibt auch während
  des Stoppens möglich.
- **0.1.3 – 29.09.2026:** Der Webschalter sichert und entfernt ausschließlich
  `kienzlefax.php`; die Aktivierung stellt die Datei samt Besitzer und Rechten wieder
  her. Apache-Sperrkonfiguration und HTTP-/HTTPS-Prüfungen entfallen für neue Pausen.
  Gespeicherte Sperren früherer Versionen bleiben rücknehmbar.
- **0.1.2 – 29.09.2026:** Die Faxabschaltung akzeptiert den bereits freigegebenen
  Telefonie-Datei-Include auch nach dem letzten Dialplan-Kontext. Tests verwenden
  den vollständigen Installer-Dialplan einschließlich angehängter Abschlusszeile
  und prüfen Abschaltung, Rücknahme sowie weiterhin abgewiesene fremde Anweisungen.
- **0.1.1 – 29.09.2026:** Wiederholte Samba-`[global]`-Abschnitte verhindern die
  Bestandsaufnahme nicht mehr. Alle globalen Blöcke und Fremdfreigaben bleiben
  bei der Verwaltung und Rücknahme unverändert. Regressionstests decken eine
  gemeinsame Installation mit weiteren Anwendungen ab.
- **0.1.0 – 29.09.2026:** Erster separater Verwaltungsassistent mit einzeln wählbaren
  Bereichen, Vorschau, geschützten Sicherungen, Abweichungserkennung und Rücknahme.

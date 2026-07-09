# kienzlefax Arbeitsregeln

Diese Datei fasst die Projektvorgaben zusammen. Sie dient als verbindliche Arbeitsnotiz fuer Aenderungen an diesem Repo.

## Grundsatz

- Arbeite konservativ, minimal-invasiv und nachvollziehbar.
- Keine unabgesprochenen Strukturänderungen.
- Keine Rekonstruktion aus Vermutungen, wenn eine bestätigte Ausgangsdatei vorhanden sein sollte.
- Wenn eine passende Basisdatei fehlt oder unklar ist, vor größeren Änderungen Rückfrage halten.
- Bestehende Funktionalität darf nicht verloren gehen.
- Versionen semantisch inkrementieren; bei Installer-Änderungen zuletzt `+0.0.1`.
- Neue Versionen nur nach sorgfältiger Besprechung und expliziter Freigabe.
- Bei Installer-Änderungen den vollständigen Changelog oben fortführen, nicht entfernen.
- Wenn ein Installer oder Modul als Antwort ausgegeben wird: vollständige Datei ausgeben, nicht nur Diffs, sofern nicht ausdrücklich anders verlangt.

## Stil Und Sicherheit

- Tool- und Modul-Beschreibungen sollen mit `IMMER verwenden wenn ...` beginnen.
- Keine Secrets hart codieren, außer es wurde ausdrücklich so festgelegt.
- Private Rufnummern dürfen nicht im Installer oder in Moduldateien stehen.
- Persönliche Nummern durch Installer-Variablen setzen lassen.
- Passwörter nicht in Logs ausgeben; kein `set -x` bei Secrets.
- SIP-Passwort darf interaktiv abgefragt und in `/etc/kienzlefax-installer.env` mit `chmod 0600` gespeichert werden.
- AMI-Passwort wird nicht interaktiv abgefragt; es ist lokal und wird aus `KFX_AMI_SECRET` gesetzt.
- Bei Dateinamen nur den Zählerteil von `${UNIQUEID}` verwenden, also den Teil nach dem Punkt.

## Zielarchitektur Installer

- Der alte große `kienzlefax`-Installer soll modularisiert werden.
- `kienzlefax-installer.sh` im Repository-Root ist nur der schlanke Bootstrap und lädt `installer-modular/kienzlefax-install-modular.sh` von GitHub.
- Der vollständige Hauptinstaller liegt ausschließlich unter `installer-modular/kienzlefax-install-modular.sh`.
- Es gibt einen Hauptinstaller und mehrere Remote-Module als `.sh`-Dateien.
- Alles gehört grundsätzlich zur Installation; aktuell keine optionalen Module.
- Optional soll später nur providerabhängige Konfiguration werden.
- Der Installer bietet zusätzlich den Modus `KFX_QUEUE_ONLY=y` fuer ausschliesslich Telefoniewarteschlange an.
- Queue-only installiert keine Fax-DID/Provider-Nebenstelle, Faxdrucker, Fax-/OCR-Verzeichnisse, Weboberflaeche, Samba, CUPS, AMI, AGI, Faxworker oder PDF-Berichte.
- Queue-only behaelt Asterisk, RTP, Telefonie-PJSIP, lokale Nebenstellen, Queue, Kanalbegrenzung und deutsche Positionsansagen; Konfiguration und Passwoerter stehen nur in `/etc/kienzlefax-installer.env` (0600).
- Ein Wechsel zu Queue-only entfernt vorhandene Faxkomponenten nicht automatisch; der Installer muss dies transparent ausgeben.
- Bei jedem Queue-only-Installerlauf werden PJSIP-, Dialplan- und Queue-Dateien erneut aus `/etc/kienzlefax-installer.env` generiert, auch wenn keine Remote-Datei aktualisiert wird.
- Remote-Module werden per Bootstrap aus GitHub geholt und ausgeführt.
- Der Installer fragt fuer jede einzelne Remote-Datei separat, ob sie neu heruntergeladen oder aktualisiert werden soll:
  - Datei fehlt: Default `ja`
  - Datei existiert: Default `nein`
- Der Installer fragt ebenfalls, ob `kienzlefax.php` im Webroot neu heruntergeladen oder aktualisiert werden soll:
  - Datei fehlt: Default `ja`
  - Datei existiert: Default `nein`
- Am Anfang fragt der Installer, ob Optionen neu gesetzt werden sollen.
- Wenn `/etc/kienzlefax-installer.env` vorhanden ist, ist der Default: vorhandene Optionen weiterverwenden.
- Installer-Dialoge sollen am Anfang gesammelt werden. Der lange Installationslauf soll danach ohne weitere Rueckfragen laufen.
- Grundkonfiguration darf wiederverwendet werden, aber Laufoptionen muessen bei jedem Installerstart neu gefragt werden: Remote-Module aktualisieren, Weboberflaeche aktualisieren, Asterisk-Rebuild, manuelles menuselect, Installationsbericht, optionaler Benutzerentfernungs-Schritt.
- Wenn Asterisk erkannt wird, fragt der Installer am Anfang, ob Asterisk erneut kompiliert werden soll; Default bei vorhandenem Asterisk: `nein`.
- Der Installer fragt am Anfang ein Admin-Passwort ab und setzt damit Linux-User `admin` und Samba-User `admin`; `admin` muss normale sudo-Rechte mit Passwortabfrage haben.
- Das Admin-Passwort kann am Anfang entweder manuell gesetzt oder sicher generiert werden; generierte Passwoerter nicht im Terminal-Log ausgeben, sondern nur in ENV/Installationsbericht.
- Wenn SSH auf Public-Key-only steht, soll der Installer vorhandene `authorized_keys` des bisherigen Installationsusers nach `admin` und nach `/root/.ssh/authorized_keys` uebernehmen, damit `admin` erreichbar ist und root-Wartungszugang per Key moeglich bleibt, sofern SSHD root-login erlaubt.
- Optional darf der bisherige Erstbenutzer entfernt werden, aber nur nach Sicherheitschecks und nie `root` oder `admin`.
- Falls der alte Erstbenutzer wegen aktiver SSH-/Login-Prozesse nicht direkt geloescht werden kann, muss der Installer dessen Login sperren und vorhandene SSH-Keys deaktivieren.
- Wenn User `admin` bereits existiert, fragt der Installer, ob `admin` neu generiert bzw. Passwörter neu gesetzt werden sollen; Default: `nein`.

## Aktuelle Remote-Module

- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/extensions.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pjsip-provider.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pjsip-1und1.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/telefonie-queue.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/worker.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/agi.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pdf_with_header.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/scan_ocr.sh`

## Webroot, Hostname Und Apache

- `kienzlefax.php` wird nach `/var/www/html/kienzlefax.php` gebootstrapped.
- Quelle: `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax.php`
- `index.html` im Webroot leitet auf `/kienzlefax.php` weiter.
- `faxton.mp3` soll ebenfalls ins Webroot geladen werden, wenn vom Installer vorgesehen.
- Hostname am Anfang abfragen, per `hostnamectl` setzen und `/etc/hosts` passend pflegen.
- Fuer Apache ein self-signed Zertifikat mit 50 Jahren Laufzeit erzeugen.
- Hostname muss in CN und SAN des Zertifikats verwendet werden.
- Apache SSL aktivieren und `default-ssl.conf` konservativ patchen oder erstellen.
- Web-Ziel: `http://hostname/` redirectet auf `/kienzlefax.php`; `https://hostname/` nutzt self-signed Cert.

## Asterisk

- Asterisk wird aus Source installiert, wenn noch nicht vorhanden oder wenn der Nutzer Rebuild bestätigt.
- Build-Ablauf: `git clone/fetch/checkout`, `./configure --with-pjproject-bundled`, nichtinteraktive Aktivierung der Fax-Module per `menuselect/menuselect`, optional manuelle Menuepruefung nur wenn am Anfang gewaehlt, ressourcenschonendes `make` mit max. 2 Jobs und Fallback auf `make -j1`, `make install`, `make samples`, `make config`, `ldconfig`, kontrollierter echter Asterisk-Neustart ohne aktive Kanaele.
- `make menuselect` wird standardmaessig nicht geoeffnet; falls es manuell geoeffnet wird, im Hinweis klar sagen: Beenden/Speichern mit `X`.
- Auf frischen Raspberry-Pi-OS/Systemd-Systemen darf `systemd-sysv-install enable asterisk` den Installer nicht blockieren; der Installer stellt deshalb eine native `/etc/systemd/system/asterisk.service` sicher und fuehrt `make config` nur mit Timeout aus.
- Asterisk/pjproject kann auf Raspberry Pi bei zu viel Parallelisierung mit unspezifischem `Error 2` abbrechen; Installer nicht mit `make -j$(nproc)` bauen lassen, sondern max. 2 Jobs und automatischer Retry `make -j1`.
- Nichtinteraktiv als Pflicht aktivieren: `res_fax`, `res_fax_spandsp`.
- Nach dem Build muessen `res_pjproject`, `res_pjsip`, die PJSIP-CLI und die vom Daemon geladene Source-Bibliothek `/usr/lib/libasteriskpj.so.2` geprueft werden.
- Die native Asterisk-systemd-Unit setzt `LD_LIBRARY_PATH=/usr/lib`, damit eine eventuell vorhandene Distributionsbibliothek unter dem Multiarch-Pfad nicht die Source-PJPROJECT-Bibliothek verdraengt.
- Bei aktivierter Telefoniewarteschlange wartet ein `ExecStartPre`-Helper beim Boot bis zu 90 Sekunden auf `KFX_PHONE_BIND_IP`, bevor Asterisk startet. `network-online.target` allein reicht auf DHCP-Systemen nicht verlaesslich aus, wenn kein funktionierender Wait-Online-Dienst aktiv ist.
- Versionsabhaengig optionale Menuselect-Namen wie `app_fax` und `format_tiff` nur aktivieren, wenn vorhanden; deren Fehlen darf den Build nicht abbrechen.
- Asterisk-PJSIP bindet an `0.0.0.0`.
- SIP-Port wird am Anfang abgefragt; Default `5070`.
- RTP-Range wird am Anfang abgefragt; Default `12000-12049`.
- Public FQDN / DynDNS ist optional, aber Hinweistext: `Zur optimalen Stabilität unbedingt empfohlen.`
- Portweiterleitungen nur fuer Fax-Kommunikation empfehlen: UDP SIP-Port und UDP RTP-Range.
- Webports 80/443 niemals ins Internet weiterleiten oder relativieren; Hinweis im Bericht: Das wuerde Patientendaten exponieren.
- Kanalgrenzen werden vom Installer abgefragt. Empfohlene Defaults fuer die Hauptleitung: insgesamt 4, Telefonie 3, Fax 3; Warteschlange maximal 5 wartende Anrufer.
- Eingehende und ausgehende Faxe zaehlen zur Haupt-Gesamt- und Faxgrenze.
- Eingehende Telefonate zaehlen zur Haupt-Gesamt- und Telefoniegrenze; ausgehende Telefonate zaehlen standardmaessig ebenfalls, koennen bei separater Ausgangsleitung aber explizit ausgenommen werden.
- Interne Telefonate zwischen lokalen Nebenstellen zaehlen nicht.
- Ueberlastete externe Telefonie wird vor `Answer()` mit `Hangup(17)`/SIP Busy abgewiesen, damit eine netzseitige Busy-Umleitung greifen kann.
- Ausgehende Faxe werden bei voller Kapazitaet ohne Verbrauch eines Sendeversuchs im Worker zeitversetzt zurueckgestellt.
- Optionaler, experimenteller Sipgate-Ueberlauf nutzt `sipconnect.sipgate.de`, eine eigene additive Kanalgrenze (Default 2) und fuehrt ebenfalls in dieselbe Queue. Installer und Bericht muessen ihn klar als experimentell kennzeichnen.
- Lokale SIP-Endgeraete sind standardmaessig nur aus dem erkannten internen Netz erlaubt. Optional fragt der Installer externe Erreichbarkeit und ein erlaubtes IPv4-Quellnetz ab; Default bleibt aus, bei Aktivierung klare Internet-/Firewallwarnung und weiterhin keine automatischen Firewallregeln.
- Progressive Queue-Prioritaet erweitert die klingelnden Telefone alle 20 Sekunden (19 Sekunden Rufversuch plus 1 Sekunde Retry).
- Vor den Kanalabfragen wird deutlich vor massiven Stabilitaetsproblemen bei zu hohen Werten gewarnt; jede Abweichung von den Defaults erfordert eine zweite explizite Bestaetigung.

## PJSIP / Provider

- `pjsip.conf` wird nur im Provider-Modul `pjsip-provider.sh` befüllt; `pjsip-1und1.sh` bleibt als alte 1&1-Vorlage/Kompatibilitaetsdatei erhalten.
- Keine doppelte Ownership der `pjsip.conf`.
- Das Provider-Modul arbeitet aus Installer-Variablen und sourct `/etc/kienzlefax-installer.env`.
- Installer fragt den Provider am Anfang ab: `1und1`, `telekom`, `sipgate`, `manual`. Telekom/sipgate sind Templates mit zu pruefenden Default-Feldern; bei `manual` schreibt der Installer `pjsip.conf` nicht automatisch.
- Der generische Dialplan-Endpoint ist `KFX_PJSIP_ENDPOINT`, Default `kfx-provider-endpoint`; Provider-Templates muessen diesen Endpoint bereitstellen.
- SIP-Passwoerter und andere freie String-Werte muessen shell-sicher gequotet in `/etc/kienzlefax-installer.env` stehen; ungequotete Sonderzeichen koennen zu `pjsip show registrations => Rejected` fuehren.
- Neue Variablen bevorzugt mit `KFX_*`; Legacy-Variablen wie `PJSIP_USER` und `PJSIP_PASS` nur kompatibel unterstützen.
- Keine `set -u`/unbound-variable Fehler.
- Keine undefinierten Helper-Funktionen voraussetzen.
- `transport-udp` mit `bind=0.0.0.0:${KFX_SIP_BIND_PORT}` setzen.
- Eine `type=system`-Sektion setzt `compact_headers=yes`; eine `type=global`-Sektion setzt den kurzen `user_agent=KienzleFax`. Die Systemaenderung erfordert einen kontrollierten Asterisk-Neustart und beide Werte halten grosse SIP-Antworten mit Reserve unter typischen MTU-Grenzen.
- `from_domain=sip.1und1.de`, nicht `from_domain=$sip.1und1.de`.
- `client_uri` typischerweise aus SIP-User bilden: `sip:${PJSIP_USER}@sip.1und1.de`.
- Beim Schreiben von `pjsip.conf` freie Config-Werte wie `password=` fuer Asterisk escapen, mindestens `\` und `;`; Semikolon wird sonst als Kommentarbeginn interpretiert.

## Dialplan / extensions.sh

- `extensions.conf` wird vom Modul `extensions.sh` befüllt.
- Das Modul sourct `/etc/kienzlefax-installer.env`.
- Asterisk-Runtime-Variablen wie `${KFX_JOBID}`, `${KFX_FILE}`, `${ARG1}`, `${FAXSTATUS}` und `${UNIQUEID}` dürfen nicht von Bash expandiert werden.
- Fuer Dialplan-Inhalte immer single-quoted heredoc verwenden, z. B. `cat >"$EXT" <<'EOF'`.
- Installzeitwerte nur über Platzhalter ersetzen, z. B. `__KFX_FAX_DID__`, `__KFX_CALLERID_NUM__`, `__KFX_CALLERID_NAME__`.
- Keine feste persönliche Rufnummer im Dialplan.
- `CallerID(num)` soll die SIP-Nummer aus dem Installer verwenden: `KFX_CALLERID_NUM` default = `KFX_SIP_NUMBER`.
- FAX-IN-DID kommt aus `KFX_FAX_DID`; Default = SIP-Nummer, wenn bei Abfrage Enter gedrückt wird.
- FAX-IN soll weiterhin PDF aus TIFF erzeugen und den `${UNIQUEID}`-Zählerteil nach Punkt verwenden.

## AGI

- AGI wird als separates Remote-Modul `agi.sh` installiert.
- Ziel: `/var/lib/asterisk/agi-bin/kfx_update_status.agi`.
- Zielverzeichnis anlegen, vorhandene Datei timestamped sichern.
- Datei ausführbar machen: `chmod 0755`.
- Owner: falls User `asterisk` existiert `asterisk:asterisk`, sonst `root:root`.
- Python-Syntaxcheck: `python3 -m py_compile /var/lib/asterisk/agi-bin/kfx_update_status.agi`.
- AGI darf keine Installer-Variablen benötigen.
- AGI muss robust laufen und bei Fehlern nicht den Asterisk-Call hart abbrechen.
- Version aktuell: `1.3.9`.
- Event-Style-Aufrufe: `jobid,dial_start`, `jobid,capacity_deferred`, `jobid,send_start`, `jobid,dial_end,<DIALSTATUS>,<HANGUPCAUSE>`, `jobid,send_end,<FAXSTATUS>,<FAXERROR>,<FAXPAGES>,<FAXBITRATE>,<FAXECM>,<DIALSTATUS>,<HANGUPCAUSE>`.
- Legacy-Signatur bleibt kompatibel.
- `DIALSTATUS=CANCEL` und `HANGUPCAUSE=19` wird als `NOANSWER` behandelt.
- `dial_end` mit `ANSWER` finalisiert nicht; `send_end` ist Quelle der Wahrheit.
- `NOFAX` als Reason-Klasse: `ANSWER`, aber Fax scheitert/keine Seiten -> 3 Versuche.
- JSON atomar schreiben: tmp + replace.

## Worker / AMI

- `worker.sh` wird als Remote-Modul geladen und installiert den Worker-Code.
- Der Installer selbst legt zusätzlich `/etc/default/kienzlefax-worker` an.
- `/etc/default/kienzlefax-worker` soll diese Struktur haben; `KFX_AMI_PASS` kommt aus `KFX_AMI_SECRET`:

```sh
# kienzlefax-worker env
KFX_BASE=/srv/kienzlefax

KFX_AMI_HOST=127.0.0.1
KFX_AMI_PORT=5038
KFX_AMI_USER=kfx
KFX_AMI_PASS=<aus KFX_AMI_SECRET>

KFX_DIAL_CONTEXT=fax-out

# optional tuning
KFX_MAX_INFLIGHT=2
KFX_POST_CALL_COOLDOWN_SEC=20
```

- Service-Ziel: `/etc/systemd/system/kienzlefax-worker.service`.
- Service-Inhalt:

```ini
[Unit]
Description=kienzlefax worker (Asterisk SendFAX via AMI)
After=network.target asterisk.service
Requires=asterisk.service

[Service]
Type=simple
EnvironmentFile=/etc/default/kienzlefax-worker
ExecStart=/usr/bin/python3 -u /usr/local/bin/kienzlefax-worker.py
Restart=always
RestartSec=2
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
```

- Danach: `systemctl daemon-reload` und `systemctl enable --now kienzlefax-worker`.
- AMI lokal auf `127.0.0.1:5038`.
- Manager-User: `kfx`; Secret aus `KFX_AMI_SECRET`.
- `manager.conf`: `enabled=yes`, `webenabled=no`, `bindaddr=127.0.0.1`, `port=5038`, `include manager.d/*.conf`.
- `/etc/asterisk/manager.d/kfx.conf` schreiben.
- Nur localhost erlauben: `deny=0.0.0.0/0.0.0.0`, `permit=127.0.0.1/255.255.255.255`.
- Rechte: `read = system,call,log,command,reporting`; `write = system,call,command,reporting,originate`.

## Pakete

- Paketliste aus altem funktionierenden Installer bevorzugen.
- Am Anfang: `apt-get update`, danach `apt-get -y upgrade`.
- Pakete u. a.: `ca-certificates`, `curl`, `wget`, `jq`, `acl`, `lsof`, `coreutils`, `iproute2`, `psmisc`, `apache2`, `libapache2-mod-php`, `php`, `php-cli`, `php-sqlite3`, `php-mbstring`, `sqlite3`, `qpdf`, `ghostscript`, `poppler-utils`, `libtiff-tools`, `cups`, `cups-client`, `avahi-daemon`, `avahi-utils`, `samba`, `smbclient`, `sudo`, `python3`, `python3-venv`, `python3-pip`, `python3-reportlab`, `sox`, `lame`, `build-essential`, `git`, `pkg-config`, `autoconf`, `automake`, `libtool`, `libxml2-dev`, `libncurses5-dev`, `libedit-dev`, `uuid-dev`, `libssl-dev`, `libsqlite3-dev`, `libsrtp2-dev`, `libtiff-dev`, `libjansson-dev`, `libspandsp-dev`.
- PyPDF fallback: zuerst `python3-pypdf`, dann `python3-pypdf2`; wenn beides fehlschlägt, sauber abbrechen.
- Deutsche Queue-Ansagen werden bevorzugt mit `apt-get download asterisk-prompt-de` extrahiert. Fehlt das Paket in der aktiven Debian-Suite, darf das gepruefte offizielle Debian-All-Paket von `deb.debian.org` direkt geladen und nur extrahiert werden; niemals darf dadurch das Debian-Asterisk-Paket installiert werden.
- Fuer Positionsansagen muessen mindestens `queue-thankyou.gsm`, `queue-youarenext.gsm`, `queue-thereare.gsm` und `queue-callswaiting.gsm` vorhanden sein.

## Verzeichnisse, Rechte, CUPS Und Samba

- Basis: `/srv/kienzlefax`.
- Eingänge: `/srv/kienzlefax/incoming/fax1` bis `faxN`; der Installer fragt `N` ab, Default 5, erlaubt 1 bis 100.
- Drop-in: Standard `/srv/kienzlefax/pdf-zu-fax`; optional mehrere getrennte Drop-ins `/srv/kienzlefax/pdf-zu-fax1` bis `pdf-zu-faxN` fuer Arbeitsplaetze.
- Fehler: `/srv/kienzlefax/sendefehler/eingang`, `/srv/kienzlefax/sendefehler/berichte`.
- Queue: `/srv/kienzlefax/staging`, `/srv/kienzlefax/queue`, `/srv/kienzlefax/processing`.
- Berichte: `/srv/kienzlefax/sendeberichte`.
- Phonebook: `/srv/kienzlefax/phonebook.sqlite`.
- Asterisk Fax: `/var/spool/asterisk/fax1`, `/var/spool/asterisk/fax`.
- Rechte zunächst großzügig wie im Projekt üblich; bestehende Rechte-Logik nicht ohne Rücksprache verschärfen.
- CUPS Backend: `/usr/lib/cups/backend/kienzlefaxpdf`.
- Drucker: `fax1` bis `faxN`, gemaess Installer-Abfrage.
- Backend schreibt PDFs nach `/srv/kienzlefax/incoming/fax1` bis `faxN`.
- `cups-browsed` deaktivieren, falls vorhanden, damit keine `implicitclass`-Probleme entstehen.
- Samba `smb.conf` darf deterministisch geschrieben werden, wenn bisher so vorgesehen.
- Shares: `printers`, `pdf-zu-fax` oder `pdf-zu-fax1..N`, `sendefehler-eingang`, `sendefehler-berichte`, `sendeberichte`, `fax-eingang`.
- `fax-eingang` zeigt auf `/var/spool/asterisk/fax`.
- Nach einem Asterisk-Build muss `/var/spool/asterisk` fuer `nobody` und `scanocr` traversierbar bleiben; mindestens `o+x` am Elternverzeichnis erneut sicherstellen und `/var/spool/asterisk/fax` wie vorgesehen offen halten.
- Samba-Konfiguration und Dienste duerfen nicht mit `|| true` als erfolgreich behandelt werden: `testparm`, Dienststart und lokale `smbclient`-Zugriffe auf alle Daten-Shares sind verbindlich zu pruefen.
- Der Admin-Share `sendeberichte` wird mit einer temporaeren Auth-Datei `0600` getestet; das Admin-Passwort darf dabei weder in der Kommandozeile noch im Log erscheinen.
- `sendeberichte` nur fuer `admin`, `guest ok = no`; keine nicht angelegte `force group` setzen.
- `pdf-zu-fax`/`pdf-zu-faxN` und Fehler-Eingänge `guest ok = yes`, sofern bisher so vorgesehen.
- `/srv/kienzlefax/config/sources.json` ist die verbindliche Quellenliste fuer das Webinterface. Format bleibt `schema_version`, `default_source`, `sources[]` mit `id`, `label`, `kind`, `path`, `enabled`, `sendable`, `order`.

## Scan-OCR

- Modul: `installer-modular/scan_ocr.sh`.
- Service: `scan-ocr.service`.
- Watcher: `/usr/local/bin/scan-ocr-watch.sh`.
- PDF-Metadaten-Helper: `/usr/local/bin/embed-json-in-pdf.py`.
- Technischer Nutzer: `scanocr`.
- Verzeichnisse:
  - `/srv/scan/eingang` fuer Eingang.
  - `/srv/scan/ocr` fuer OCR-Ergebnisse.
  - `/srv/scan/archiv` fuer Originale.
  - `/srv/scan/fehler` fuer nicht verarbeitbare Dateien.
  - `/var/tmp/scan-ocr` fuer temporaere Arbeitsdaten.
- Verbindliche Samba-Share-Namen:
  - `hierhin-scannen-fuer-ocr` zeigt auf `/srv/scan/eingang`.
  - `scan-eingang` zeigt auf `/srv/scan/ocr`.
- Rechte wie im Projekt ueblich offen/grosszuegig; Samba erzwingt `scanocr:scanocr`.
- Empfangene Faxe werden roh nach `/srv/scan/fax-eingang` geschrieben.
- `scan-ocr-fax.service` verarbeitet `/srv/scan/fax-eingang` nach `/var/spool/asterisk/fax`.
- Der bestehende Share `fax-eingang` zeigt weiter auf `/var/spool/asterisk/fax` und enthaelt dadurch OCR-Ergebnis oder Fallback-PDF, nicht die Roh-PDF vor OCR.
- Installationsbericht mit Klartext-Passwoertern wird standardmaessig erzeugt, wenn am Anfang nicht abgewählt. Ziel: `/var/spool/asterisk/fax/installationsbericht_kienzlefax_*_bitte_loeschen_mit_passwoertern.pdf`.
- Bericht enthaelt SIP-Passwort, Admin-Passwort, aktuelle lokale IP, Empfehlung feste IP per DHCP-Reservierung, Fax-Portweiterleitungen, wichtige Config-Dateien und Share-/Verzeichnisuebersicht.
- Ausgehende Fax-Kopfzeile darf Inhalte nicht ueberdrucken: A4 beibehalten, oben nur ein schmales Headerband reservieren, Originalinhalt minimal darunter verkleinern. Default: Headerband 6 mm, Top-Offset 4 mm, Schrift 8 pt; staerkere Verkleinerung nur nach Ruecksprache.

## Remote-Script-Kompatibilität

- Remote-Scripts sollen robust sein, `/etc/kienzlefax-installer.env` sourcen und nicht an unbound variables scheitern.
- Compatibility-Layer im Installer exportiert zusätzlich: `PJSIP_USER`, `PJSIP_PASS`, `SIP_BIND_PORT`, `SIP_PORT`, `FAX_DID`, `PUBLIC_FQDN`, `AMI_HOST`, `AMI_PORT`, `AMI_USER`, `AMI_SECRET`.
- Falls alte Remote-Scripte Helper brauchen, kann der Installer minimale Wrapper-Funktionen exportieren: `sep`, `backup_file_ts`, `ensure_line_in_file`.

## Tests Und Fehlervermeidung

- Am Ende reloaden/checken: `core reload`, `pjsip reload`, `dialplan reload`, `systemctl status apache2`, `cups`, `smbd`, `asterisk`, `kienzlefax-worker`.
- Sinnvolle Zusatzchecks: `asterisk -rx "pjsip show transports"`, `asterisk -rx "pjsip show registrations"`, `asterisk -rx "manager show settings"`, `asterisk -rx "manager show user kfx"`.
- Bei `pjsip show registrations => Rejected` zuerst `/etc/kienzlefax-installer.env` pruefen: SIP-Nummer korrekt und SIP-Passwort unverfaelscht/shell-sicher gequotet.
- Kein `awk` mit `match(..., ..., array)`, weil Debian/RPi häufig `mawk` nutzt; INI-Patching stattdessen mit Python.
- Heredocs fuer Dialplan immer quoted, damit Bash keine Asterisk-Variablen expandiert.
- PJSIP-Modul muss Variablennamen konsistent setzen und darf `PJSIP_CONF`/`PJSIP` nicht verwechseln.
- `from_domain=$sip.1und1.de` ist falsch.
- `ensure_line_in_file` und `sep` entweder definieren oder nicht benutzen.
- `KFX_JOBID`, `KFX_FILE` usw. sind Asterisk-Runtime-Variablen und dürfen nicht im Installer/Modul von Bash expandiert werden.

## Telefoniewarteschlange

- Die Telefoniewarteschlange ist eine optionale Grundkonfiguration; das Remote-Modul `telefonie-queue.sh` wird trotzdem immer gebootstrapped und ausgeführt.
- Installer-Abfragen bei aktivierter Telefonie: Zahl der Telefone, SIP-Konfiguration der Eingangsleitung, separate Ausgangsleitung ja/nein und gegebenenfalls deren SIP-Konfiguration.
- Fuer Telefonie dieselben Provider-Templates wie fuer Fax verwenden: `1und1`, `telekom`, `sipgate`, `manual`.
- Lokale PJSIP-Konten beginnen bei `201` und erhalten jeweils ein sicher generiertes Passwort.
- Vorhandene lokale PJSIP-Passwoerter fuer Telefon-Nebenstellen muessen bei erneuter Konfiguration
  standardmaessig aus `/etc/kienzlefax-installer.env` beibehalten werden; neue Passwoerter nur nach
  expliziter Rueckfrage erzeugen. Neu hinzugekommene oder fehlende Nebenstellenpasswoerter werden
  automatisch generiert.
- Passwoerter nicht im Terminal oder Log ausgeben; shell-sicher in `/etc/kienzlefax-installer.env` mit `0600` und im aktivierten Installationsbericht dokumentieren.
- Interner SIP-Port ist `5060`; der Provider-/Fax-Port `5070` bleibt unveraendert extern nutzbar.
- Interne Bind-IP und internes IPv4-Netz werden aus der Standardschnittstelle erkannt, transparent ausgegeben und im Installationsbericht dokumentiert; niemals ein Praxisnetz fest codieren.
- Keine Firewall-, `ufw`- oder `nftables`-Regeln erzeugen. Lokale Endpunkte per PJSIP-ACL auf das erkannte interne Netz begrenzen.
- Wenn externe SIP-Erreichbarkeit mit `KFX_PHONE_ALLOWED_CIDR=0.0.0.0/0` bewusst erlaubt wird,
  keine redundante `deny all`/`permit all`-PJSIP-ACL schreiben, sondern transparent kommentieren,
  dass der Schutz Betreiberaufgabe ist.
- Pro Telefon genau ein eigener PJSIP-Endpunkt; die FRITZ!Box ordnet jedes Konto genau einem Empfangstelefon zu.
- Fuer Telefonie G.722 als bevorzugten Codec vor G.711 konfigurieren: `allow=g722,alaw,ulaw`; Fax-Codecs dadurch nicht veraendern.
- Standardverteilung: Telefon 1 zuerst; bei Besetzt sofort das naechste freie Telefon. Ohne Annahme kommt alle 15 Sekunden die naechste Prioritaetsstufe hinzu.
- Queue: `ringall` mit aufsteigenden Penalties, `ringinuse=no`, `autofill=yes`, korrektem `state_interface` und Endpunkten mit `device_state_busy_at=1`.
- Bis eine lizenzierte Wartemusik geliefert wird, Queue-Option `r` fuer Klingelzeichen statt Music-on-Hold verwenden.
- Deutsche Standard-Warteansage erstmals nach 60 Sekunden und danach alle 60 Sekunden, keine Positions- oder Wartezeitausgabe. `announce-to-first-user=no`, damit Telefon 1 sofort gerufen wird. `CHANNEL(language)=de` setzen und benoetigte Dateien vor Aktivierung pruefen.
- `asterisk-prompt-de` nicht per APT installieren, weil dies den Distributions-Asterisk und eine kollidierende PJPROJECT-Bibliothek nachziehen kann. Nur das Paket herunterladen, mit `dpkg-deb` extrahieren und die deutschen Audiodateien uebernehmen.
- Fax- und Telefonie-DID muessen verschieden sein. Provider-Endpunkte landen im gemeinsamen Context `kfx-provider-in`, der anhand der DID zu Fax oder Queue verteilt.
- Alte Asterisk-Systeme und direkte Provider-Registrierungen derselben Rufnummern koennen nicht automatisch abgemeldet werden. Installer-Ausgabe und Installationsbericht muessen darauf hinweisen, dass sie deaktiviert sein muessen.
- Telefonie-Konfiguration in getrennten Dateien halten: `pjsip-kfx-telefonie.conf`, `extensions-kfx-telefonie.conf`, `queues-kfx.conf`, `queuerules-kfx.conf`.
- Nach Telefonie-Konfigurationsaenderungen nicht nur `pjsip show transport` pruefen, sondern mit `ss` sicherstellen, dass der Asterisk-Prozess tatsaechlich auf der erkannten internen IP und UDP-Port 5060 lauscht; andernfalls kontrolliert neu starten oder sauber abbrechen.

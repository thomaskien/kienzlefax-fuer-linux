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
- Es gibt einen Hauptinstaller und mehrere Remote-Module als `.sh`-Dateien.
- Alles gehört grundsätzlich zur Installation; aktuell keine optionalen Module.
- Optional soll später nur providerabhängige Konfiguration werden.
- Remote-Module werden per Bootstrap aus GitHub geholt und ausgeführt.
- Der Installer fragt fuer jede einzelne Remote-Datei separat, ob sie neu heruntergeladen oder aktualisiert werden soll:
  - Datei fehlt: Default `ja`
  - Datei existiert: Default `nein`
- Der Installer fragt ebenfalls, ob `kienzlefax.php` im Webroot neu heruntergeladen oder aktualisiert werden soll:
  - Datei fehlt: Default `ja`
  - Datei existiert: Default `nein`
- Am Anfang fragt der Installer, ob Optionen neu gesetzt werden sollen.
- Wenn `/etc/kienzlefax-installer.env` vorhanden ist, ist der Default: vorhandene Optionen weiterverwenden.
- Wenn Asterisk erkannt wird, fragt der Installer, ob Asterisk erneut kompiliert werden soll; Default bei vorhandenem Asterisk: `nein`.
- Wenn User `admin` bereits existiert, fragt der Installer, ob `admin` neu generiert bzw. Passwörter neu gesetzt werden sollen; Default: `nein`.

## Aktuelle Remote-Module

- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/extensions.sh`
- `https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pjsip-1und1.sh`
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
- Build-Ablauf: `git clone/fetch/checkout`, `./configure`, interaktives `make menuselect`, `make -j"$(nproc)"`, `make install`, `make samples`, `make config`, `ldconfig`, `systemctl enable --now asterisk`.
- `make menuselect` bleibt interaktiv.
- In `menuselect` mindestens prüfen/aktivieren: `res_fax`, `app_fax` / `SendFAX` / `ReceiveFAX`, `res_fax_spandsp` falls verfügbar/gewünscht, `format_tiff`, passende Codecs nach Bedarf.
- Asterisk-PJSIP bindet an `0.0.0.0`.
- SIP-Port wird am Anfang abgefragt; Default `5070`.
- RTP-Range wird am Anfang abgefragt; Default `12000-12049`.

## PJSIP / Provider 1und1

- `pjsip.conf` wird nur im Provider-Modul `pjsip-1und1.sh` befüllt.
- Keine doppelte Ownership der `pjsip.conf`.
- Das Provider-Modul arbeitet aus Installer-Variablen und sourct `/etc/kienzlefax-installer.env`.
- SIP-Passwoerter und andere freie String-Werte muessen shell-sicher gequotet in `/etc/kienzlefax-installer.env` stehen; ungequotete Sonderzeichen koennen zu `pjsip show registrations => Rejected` fuehren.
- Neue Variablen bevorzugt mit `KFX_*`; Legacy-Variablen wie `PJSIP_USER` und `PJSIP_PASS` nur kompatibel unterstützen.
- Keine `set -u`/unbound-variable Fehler.
- Keine undefinierten Helper-Funktionen voraussetzen.
- `transport-udp` mit `bind=0.0.0.0:${KFX_SIP_BIND_PORT}` setzen.
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
- Version aktuell: `1.3.6`.
- Event-Style-Aufrufe: `jobid,send_start`, `jobid,dial_end,<DIALSTATUS>,<HANGUPCAUSE>`, `jobid,send_end,<FAXSTATUS>,<FAXERROR>,<FAXPAGES>,<FAXBITRATE>,<FAXECM>,<DIALSTATUS>,<HANGUPCAUSE>`.
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

## Verzeichnisse, Rechte, CUPS Und Samba

- Basis: `/srv/kienzlefax`.
- Eingänge: `/srv/kienzlefax/incoming/fax1` bis `fax5`.
- Drop-in: `/srv/kienzlefax/pdf-zu-fax`.
- Fehler: `/srv/kienzlefax/sendefehler/eingang`, `/srv/kienzlefax/sendefehler/berichte`.
- Queue: `/srv/kienzlefax/staging`, `/srv/kienzlefax/queue`, `/srv/kienzlefax/processing`.
- Berichte: `/srv/kienzlefax/sendeberichte`.
- Phonebook: `/srv/kienzlefax/phonebook.sqlite`.
- Asterisk Fax: `/var/spool/asterisk/fax1`, `/var/spool/asterisk/fax`.
- Rechte zunächst großzügig wie im Projekt üblich; bestehende Rechte-Logik nicht ohne Rücksprache verschärfen.
- CUPS Backend: `/usr/lib/cups/backend/kienzlefaxpdf`.
- Drucker: `fax1` bis `fax5`.
- Backend schreibt PDFs nach `/srv/kienzlefax/incoming/fax1` bis `fax5`.
- `cups-browsed` deaktivieren, falls vorhanden, damit keine `implicitclass`-Probleme entstehen.
- Samba `smb.conf` darf deterministisch geschrieben werden, wenn bisher so vorgesehen.
- Shares: `printers`, `pdf-zu-fax`, `sendefehler-eingang`, `sendefehler-berichte`, `sendeberichte`, `fax-eingang`.
- `fax-eingang` zeigt auf `/var/spool/asterisk/fax`.
- `sendeberichte` nur fuer `admin`, `guest ok = no`.
- `pdf-zu-fax` und Fehler-Eingänge `guest ok = yes`, sofern bisher so vorgesehen.

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
  - `scan-to-ocr` zeigt auf `/srv/scan/eingang`.
  - `scan-eingang` zeigt auf `/srv/scan/ocr`.
- Rechte wie im Projekt ueblich offen/grosszuegig; Samba erzwingt `scanocr:scanocr`.
- Empfangene Faxe werden roh nach `/srv/scan/fax-eingang` geschrieben.
- `scan-ocr-fax.service` verarbeitet `/srv/scan/fax-eingang` nach `/var/spool/asterisk/fax`.
- Der bestehende Share `fax-eingang` zeigt weiter auf `/var/spool/asterisk/fax` und enthaelt dadurch OCR-Ergebnis oder Fallback-PDF, nicht die Roh-PDF vor OCR.

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

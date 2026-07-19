# KienzleFax und Telefoniewarteschlange

**Faxserver und optionale Asterisk-Telefoniewarteschlange für Arztpraxen und andere kleine Einrichtungen**

**Installerstand:** 3.4.0 · **Zielsystem:** Debian Linux · **Telefonie:** Asterisk/PJSIP

https://www.kienzlefax.de

- läuft einfach in einer VM auf dem server
- alles open source und unter linux
- angebunden per SIP direkt an die eigene nummer
- optimal für den workflow von arztpraxen
- stabiler empfang und senden
- voll anpassbar
- papierfreies fax: ende der zettelwirtschaft
- optimale lesbarkeit der wichtigen befunde da nicht z.B "mal wieder bei fast leerem toner ausgedruckt und anschließend gefaxt" wird
- clients drucken einfach auf einem freigegebenen windows-drucker aus (geht von windows, linux, mac, ega)
- separater faxdrucker für jeden arbeitsplatz
- wenn der server läuft absichern nicht vergessen: sichere passwörter, ssh-mit key usw

## Installation

Als `root` im gewünschten Arbeitsverzeichnis:

```bash
wget https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax-installer.sh
chmod +x kienzlefax-installer.sh
./kienzlefax-installer.sh
```

Der Bootstrap lädt den modularen Hauptinstaller. Grundoptionen werden in
`/etc/kienzlefax-installer.env` gespeichert; die Datei enthält Passwörter und hat den Modus `0600`.
Bei einem erneuten Lauf können vorhandene Optionen weiterverwendet werden. Die Asterisk-Dateien
werden anschließend erneut aus der ENV erzeugt, auch wenn keine Remote-Module aktualisiert werden.
Lokale SIP-Passwörter für Telefon-Nebenstellen bleiben bei erneuter Konfiguration standardmäßig
erhalten; neue Passwörter werden nur nach expliziter Rückfrage erzeugt.
Für 1&1 stehen getrennte UDP- und TLS-Templates zur Verfügung. Bei aktivierter Telefoniewarteschlange
kann außerdem ein separater WireGuard-Telefonie-Installer für die Ausführung im Anschluss gewählt werden.

## Installationsmodi

### Vollinstallation

Installiert den Faxworkflow mit Asterisk, Faxempfang und -versand, Faxdruckern, Weboberfläche,
Samba, OCR, Worker und optionaler Telefoniewarteschlange.

### Nur Telefoniewarteschlange

Setzt `KFX_QUEUE_ONLY=y` und installiert ausschließlich:

- Asterisk/PJSIP und RTP
- lokale SIP-Nebenstellen, standardmäßig ab `201`
- die Telefoniewarteschlange und ihre Kanalbegrenzungen
- deutsche Positionsansagen

Nicht installiert werden Fax-DID oder Fax-Endpunkt, Faxdrucker, CUPS/Samba, Weboberfläche,
OCR, AMI, AGI, Faxworker oder ein Installations-PDF. Konfiguration und Passwörter stehen nur
in `/etc/kienzlefax-installer.env`. Bereits vorhandene Faxkomponenten werden beim Wechsel in
diesen Modus nicht automatisch entfernt.

## Verhalten der Telefoniewarteschlange

- Das erste freie Telefon klingelt zuerst.
- Ist es belegt, beginnt unmittelbar das nächste freie Telefon.
- Wird nicht abgenommen, kommt alle 20 Sekunden das nächste Telefon hinzu.
- Die Warteposition wird sofort beim Eintritt und anschließend höchstens einmal pro Minute angesagt.
- Als Wartesignal wird ein Klingelzeichen statt Wartemusik verwendet.
- Telefonie bevorzugt `G.722`, danach `alaw` und `ulaw`.
- Überlast wird vor Annahme mit Q.850 Cause 17 beziehungsweise SIP `486 Busy Here` abgewiesen.
- Eine netzseitige Besetztumleitung kann dadurch greifen; Steuercodes sind providerabhängig.
- Interne Nebenstellenanrufe klingeln nur bei freiem Ziel; Anklopfen wird mit SIP-Besetzt verhindert.

Empfohlene Standardgrenzen für die Hauptleitung sind vier externe Kanäle insgesamt,
davon höchstens drei für Telefonie und bei der Vollinstallation höchstens drei für Fax.
Die maximale Anzahl wartender Anrufer ist standardmäßig fünf. Der experimentelle
Sipgate-Überlauf über `sipconnect.sipgate.de` hat eine separate additive Grenze von zwei Kanälen.

## SIP-Zugriff und Sicherheit

Lokale Nebenstellen dürfen sich standardmäßig nur aus dem automatisch erkannten internen Netz
registrieren. Der Installer kann optional Registrierungen aus anderen Netzen oder dem Internet
zulassen und fragt dafür ein erlaubtes IPv4-Quellnetz ab. `0.0.0.0/0` erlaubt das gesamte Internet
und sollte nur mit zusätzlichen Schutzmaßnahmen verwendet werden. Bei konkreten Quellnetzen schreibt
der Installer eine PJSIP-ACL nach dem Muster „deny all, permit Netz“; bei `0.0.0.0/0` wird keine
redundante PJSIP-ACL geschrieben.

Der Installer richtet bewusst keine Firewallregeln ein. Betreiber müssen insbesondere Firewall,
Quellnetzbegrenzung, starke Passwörter und gegebenenfalls Angriffsschutz selbst konfigurieren.
Webports `80/443` der Fax-Vollinstallation dürfen wegen der enthaltenen Patientendaten nicht ins
Internet weitergeleitet werden.

## Optionale WireGuard-Telefonie

Der WireGuard-Folgeinstaller wird nur nach vorheriger Auswahl und erst nach Abschluss der
Hauptinstallation gestartet. Er erzeugt FRITZ!Box-Konfigurationen ohne Routing, NAT oder
Firewallregeln. Wird der interne Asterisk-Transport auf WireGuard umgestellt, speichert er Interface,
VPN-IP, Netz und SIP-Port dauerhaft in `/etc/kienzlefax-installer.env`. Ein Asterisk-Neustart erfolgt
nur ohne aktive Kanäle; anschließend werden Transport und tatsächlich geöffneter UDP-Socket geprüft.

**Einfach was ausdrucken auf einem der faxdrucker:**

<img src="Screenshot 2026-02-14 at 11.57.13.png" alt="drawing" width="800"/>

**Eine oder mehrere Dateien zum versenden auswählen:**

<img src="Screenshot 2026-02-14 at 11.57.36.png" alt="drawing" width="800"/>

**Faxe werden je datei einzeln abgeschickt, ggf mehrere an die selbe Nummer hintereinander:**
<img src="Screenshot 2026-02-14 at 11.58.14.png" alt="drawing" width="800"/>

**Sendeberichte:**

<img src="Screenshot 2026-02-14 at 12.08.20.png" alt="drawing" width="800"/>





# Historische Systemdesign-Notizen

> Die folgenden Abschnitte dokumentieren den früheren Entwurfsstand vom 13.02.2026.
> Hinweise auf HylaFAX und feste fünf Drucker sind historisch; maßgeblich sind der aktuelle
> modulare Installer, `AGENTS.md` und die vorstehenden Installationsmodi.

**Historischer Stand:** 2026-02-13  
**Historisches Ziel:** Ubuntu-LTS-Faxworkflow (SMB→PDF→Web-UI→Queue→Worker→HylaFAX→Archiv/Fehler).

---

## 1) Zielbild
- Mehrere Eingangsquellen liefern PDFs:
  - SMB-“Drucker” **fax1..fax5** schreiben PDFs serverseitig in Verzeichnisse.
  - Zusätzliches Drop-in **pdf-zu-fax** (SMB-Share) für direkt abgelegte PDFs.
- Versand erfolgt **nur über das Web-UI** (keine direkte Sendelogik in PHP).
- Web-UI erzeugt Jobs (PDF + job.json) in der Queue.
- Separater Worker-Dienst (systemd, eigener User) sendet Jobs via HylaFAX (`sendfax`), erzeugt einen **PDF-Sendebericht**, merge’t ihn mit dem Dokument und legt Ergebnis in Archiv/Fehlerbereich ab.
- **Archiv ist flach**, keine Unterverzeichnisse, **keine Redundanz**:
  - pro erfolgreichem Fax genau **2 Dateien**: `<...>__OK.pdf` und `<...>.json`.
- Eingangsverzeichnis **fax-eingang** für den Import der Faxe ins PVS oder x.archiv oder was auch immer man benutzt.

---

## 2) Begriffe / feste Namen
- Drucker-Namen: **fax1, fax2, fax3, fax4, fax5**
- Drop-in-Verzeichnis: **pdf-zu-fax**
- Fehlerbereich: **sendefehler** (bewusst guest-write)
- Archiv-Share: **sendeberichte** (nur Archiv, admin-only)

---

## 3) Verzeichnislayout
Basis: `/srv/kienzlefax/`

### 3.1 Eingang (aus “Druckern”)
`/srv/kienzlefax/incoming/`
- `fax1/`
- `fax2/`
- `fax3/`
- `fax4/`
- `fax5/`

### 3.2 Drop-in (ohne Drucken)
`/srv/kienzlefax/pdf-zu-fax/`

### 3.3 Queue (Producer → Consumer)
- `/srv/kienzlefax/staging/` (Web-UI baut Jobordner hier)
- `/srv/kienzlefax/queue/` (fertige Jobs)
- `/srv/kienzlefax/processing/` (vom Worker geclaimte Jobs)

### 3.4 Archiv (admin-only Share “sendeberichte”, flach)
`/srv/kienzlefax/sendeberichte/`
- `<basename>__<jobid>__OK.pdf`
- `<basename>__<jobid>.json`

### 3.5 sendefehler (guest-write) – zweigeteilt
A) Drop-in / Nachbearbeitung (Original unverändert, OHNE Report):
- `/srv/kienzlefax/sendefehler/eingang/<original>.pdf`

B) Fehler-Ausgabe (Report+Dokument, NICHT sendbar):
- `/srv/kienzlefax/sendefehler/berichte/<basename>__<jobid>__FAILED.pdf`
- `/srv/kienzlefax/sendefehler/berichte/<basename>__<jobid>.json`

### 3.6 Telefonbuch
`/srv/kienzlefax/phonebook.sqlite`

### 3.7 Web
- einzige PHP-Datei: `/var/www/html/kienzlefax.php`
- optional statisch (admin-only): `/var/www/html/webroot/`

---

## 4) Exklusionsregel (wichtig)
Ziel: `sendefehler/eingang` ist sendbar, `sendefehler/berichte` niemals.

Web-UI bietet als sendbare Quellen nur:
- `incoming/fax1..fax5`
- `pdf-zu-fax`
- `sendefehler/eingang` (im UI: `src=sendefehler`)

Defensiver Dateifilter in sendbaren Quellen:
- nur `*.pdf`
- Dateiname darf NICHT enden auf `__OK.pdf` oder `__FAILED.pdf`
- Dateiname darf NICHT `__REPORT__` enthalten (reserviert)

Benennung (filterbar):
- Archiv-PDF: `<basename>__<jobid>__OK.pdf`
- Fehler-PDF: `<basename>__<jobid>__FAILED.pdf`
- JSON: `<basename>__<jobid>.json`

---

## 5) Execution Model (Producer–Consumer)
### 5.1 Producer: Web-UI (PHP)
- Web-UI sendet **nicht** selbst.
- Web-UI erzeugt Jobordner:
  - `/srv/kienzlefax/queue/<jobid>/doc.pdf`
  - `/srv/kienzlefax/queue/<jobid>/job.json`
- Quelle kann sein: `fax1..fax5`, `pdf-zu-fax`, `sendefehler/eingang`

### 5.2 Consumer: Worker (systemd service)
- eigener User, z.B. `faxworker`
- Worker:
  1) claimt Job: `queue/<jobid> → processing/<jobid>` (atomic rename)
  2) ruft `sendfax` auf
  3) finalisiert Ergebnis über HylaFAX `doneq/q<JID>`
  4) erzeugt Report-PDF + merged PDF
  5) schreibt final `job.json`
  6) legt Erfolg im Archiv ab, Fehler im sendefehler-Bereich
  7) räumt processing/<jobid> auf

---

## 6) Job-Format
Jobordner: `/srv/kienzlefax/queue/<jobid>/`

**doc.pdf**  
**job.json (Minimal durch UI):**
```json
{
  "job_id": "JOB-YYYYMMDD-HHMMSS-rand",
  "created_at": "ISO8601",
  "source": { "src": "fax1|...|sendefehler", "filename_original": "..." },
  "recipient": { "name": "...", "number": "49...." },
  "options": { "ecm": true, "resolution": "fine|standard" },
  "status": "queued"
}
```

## 7) HylaFAX: Realisierter Finalize-Mechanismus (B)
Finalisierung erfolgt nicht “naiv” nur über Rückgabecode von `sendfax`, sondern über:
- `sendfax` liefert **request id = JID**
- Worker beobachtet `/var/spool/hylafax/doneq/q<JID>` und entscheidet:
  - `statuscode == 0` → OK
  - sonst → FAILED
- Dadurch sind parallele Sends zuverlässig matchbar, auch bei mehreren gleichzeitigen Jobs.

---

## 8) PDF-Sendebericht
Der Worker erzeugt pro Job einen **PDF-Sendebericht** (Seite 1) und merge’t ihn mit dem gesendeten Dokument (Seite 2..n).

Erforderliche Felder (aus doneq/q<JID> und job.json):
- Status (deutlich: **ERFOLGREICH** / **FEHLGESCHLAGEN**)
- Empfängername, Faxnummer
- Dokumentname
- Seiten (npages/totpages)
- Signalrate
- CSI
- Dauer (aus Start/Ende; im UI als Differenz berechnet)
- HylaFAX JID, CommID

Archiv/Fehler-PDF enthält **Report + Dokument in einer Datei** (keine separaten report/doc Dateien).

---

## 9) Header-Erweiterung (neu umgesetzt)
**Änderung nach Absprache:** Direkt vor `sendfax` wird optional ein Header in das PDF eingearbeitet.

### 9.1 Mechanik
- Worker versucht, vor dem Versand `doc.pdf` per Script zu verarbeiten:
  - Script: `/usr/local/bin/pdf_with_header.sh`
  - Aufruf: `pdf_with_header.sh <in.pdf> <out.pdf>`
- Outputdatei im Jobdir:
  - `doc_hdr.pdf` (aus `doc.pdf`)

### 9.2 Regeln
- Für `sendfax` wird **doc_hdr.pdf** verwendet, wenn das Script vorhanden ist und erfolgreich erzeugt.
- Für Report-Merge (Archiv/Fehler-PDF) wird **die gleiche Version wie gesendet** verwendet (Header-Version).
- Unverändertes Original bleibt für Fehler-Drop-in:
  - Bei FAILED wird **source.pdf** (Original) nach `sendefehler/eingang/` kopiert.
- Fallback:
  - Wenn Script fehlt oder fehlschlägt → Versand ohne Header (doc.pdf).

---

## 10) CUPS “Drucker” → PDF-Ablage (realisiert)
Es werden 5 CUPS-Queues `fax1..fax5` angelegt, die **PDF-Dateien direkt in**
`/srv/kienzlefax/incoming/faxX/` schreiben.

### 10.1 Technische Umsetzung (robust)
- Custom CUPS backend:
  - `/usr/lib/cups/backend/kienzlefaxpdf`
- DeviceURI pro Queue:
  - `kienzlefaxpdf:/fax1` … `kienzlefaxpdf:/fax5`
- Das Backend erzwingt PDF-Ausgabe (Ghostscript) und schreibt ins Zielverzeichnis.

### 10.2 AppArmor Hinweis
CUPS läuft häufig unter AppArmor. Bei Problemen:
- CUPS-Scheduler “shutting down due to program error”
- Backend bricht ab / keine PDFs erscheinen
Dann AppArmor-Regeln prüfen/anpassen oder temporär “complain” für cupsd setzen.

---

## 11) Rechtekonzept (praktisch bewährt)
Damit CUPS (`lp`), Apache (`www-data`) und Worker (`faxworker`) zuverlässig arbeiten und Dateien verschieben können:

### 11.1 Gemeinsame Gruppe
- Systemgruppe: `kienzlefax`
- Mitglieder: `lp`, `www-data`, `faxworker`, `admin` (und ggf. Login-User)

### 11.2 Setgid + Default-ACL
- Verzeichnisse unter `/srv/kienzlefax` gruppenschreibbar und setgid
- Default-ACL stellt sicher, dass neu erzeugte Dateien/Ordner automatisch gruppen-rwx erhalten.
- Kritisch für:
  - `/srv/kienzlefax/staging`, `/srv/kienzlefax/queue`, `/srv/kienzlefax/processing`
  - `/srv/kienzlefax/incoming/fax1..fax5`

---

## 12) Samba-Shares (Konzept)
### Guest/Everyone (bewusst write)
- `[pdf-zu-fax]` → `/srv/kienzlefax/pdf-zu-fax`
- `[sendefehler]` → `/srv/kienzlefax/sendefehler`

### Admin-only
- `[sendeberichte]` → `/srv/kienzlefax/sendeberichte`
- `[webroot]` → `/var/www/html/webroot`

Drucker-Freigabe (SMB) erfolgt separat; im Setup werden CUPS-Queues bereitgestellt.

---

## 13) UI-Konzept (eine PHP-Datei)
### Quellen / Views (bookmarkbar)
- `?src=fax1|fax2|fax3|fax4|fax5|pdf-zu-fax|sendefehler`
  - `src=sendefehler` zeigt `sendefehler/eingang`
- `?view=sendelog|phonebook|sendefehler-berichte`

### Navigation immer sichtbar
- Tabs für sendbare Quellen
- Sendeprotokoll (letzte 25) aus Archiv-JSONs
- Telefonbuch
- Sendefehler-Berichte (Ansicht-only)

### Aktive Jobs immer sichtbar
- Counts/Listen aus `queue/` und `processing/`

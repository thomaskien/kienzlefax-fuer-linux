# kienzlefax
**der ideale Faxserver für die Arztpraxis**

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

**Einfach was ausdrucken auf einem der faxdrucker:**

<img src="Screenshot 2026-02-14 at 11.57.13.png" alt="drawing" width="800"/>

**Eine oder mehrere Dateien zum versenden auswählen:**

<img src="Screenshot 2026-02-14 at 11.57.36.png" alt="drawing" width="800"/>

**Faxe werden je datei einzeln abgeschickt, ggf mehrere an die selbe Nummer hintereinander:**
<img src="Screenshot 2026-02-14 at 11.58.14.png" alt="drawing" width="800"/>

**Sendeberichte:**

<img src="Screenshot 2026-02-14 at 12.08.20.png" alt="drawing" width="800"/>





# kienzlefax – Systemdesign (README.md)
**Stand:** 2026-02-13  
**Ziel:** Ubuntu LTS Fax-Workflow mit maximaler Robustheit (SMB→PDF→Web-UI→Queue→Worker→HylaFAX→Archiv/Fehler).

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

---

## 14) Offene Punkte (für weitere README-Dateien)
Die Einrichtung weiterer Komponenten (z.B. Asterisk/IAX/Modem/Gateway, HylaFAX-Modem-Setup, Firewall, TLS/Reverse Proxy) wird in **separaten README.md** dokumentiert und hier später verlinkt.

Geplante weitere Dokumente:
- **README-Asterisk.md** – Asterisk/IAX/Gateway-Setup für Fax
- **README-HylaFAX.md** – HylaFAX-Konfiguration, Modems, Routing
- **README-Samba.md** – Shares + Druckerfreigabe + Rechte/ACL
- **README-Troubleshooting.md** – typische Fehlerbilder (CUPS/AppArmor, Worker, doneq, Rechte)

# kienzlefax – Installation (README.md)
**Stand:** 2026-02-13  
Diese Anleitung beschreibt die **Basis-Installation** von `kienzlefax` (Web-UI + Worker + Verzeichnislayout + Samba-Shares + CUPS-PDF-Drop-Drucker).  
**HylaFAX und Asterisk** werden in separaten Dokumenten detailliert; hier gibt es dafür bewusst erst Platzhalter-Blöcke.

---

## 0) Platzhalter: Technische Einrichtung HylaFAX & Asterisk (kommt als nächstes)
> **Hier folgt später die konkrete technische Einrichtung** (Modem/ATA/Gateway, Asterisk Dialplan, IAX/SIP, Fax-Empfang, HylaFAX Modem/Classes, Routing, etc.).  
> Bitte hier künftig die Inhalte aus den weiteren Readmes einfügen bzw. verlinken:
- `README-HylaFAX.md` (Modem/Config/Send/Receive)
- `README-Asterisk.md` (Gateway/IAX/SIP/Dialplan/Faxreceive)

---

## 1) Systemvoraussetzungen
- Ubuntu LTS (empfohlen: 22.04/24.04)
- Root-Zugriff (oder `sudo`)
- Server-IP im LAN
- DNS/Hostname gesetzt (optional, aber hilfreich)

---

## 2) Verzeichnislayout anlegen (kienzlefax)
```bash
sudo bash -euxo pipefail <<'EOF'
# Basis
mkdir -p /srv/kienzlefax

# Eingänge (Drucker)
for i in 1 2 3 4 5; do
  mkdir -p "/srv/kienzlefax/incoming/fax$i"
done

# Drop-ins
mkdir -p /srv/kienzlefax/pdf-zu-fax
mkdir -p /srv/kienzlefax/sendefehler/eingang
mkdir -p /srv/kienzlefax/sendefehler/berichte

# Queue-Layer
mkdir -p /srv/kienzlefax/staging
mkdir -p /srv/kienzlefax/queue
mkdir -p /srv/kienzlefax/processing

# Archiv
mkdir -p /srv/kienzlefax/sendeberichte

# Telefonbuch-DB Platzhalter (wird vom Web-UI erstellt, falls nicht vorhanden)
touch /srv/kienzlefax/phonebook.sqlite

# Optional: Webroot (admin-only Share)
mkdir -p /var/www/html/webroot

EOF
```

## 3) Pakete installieren (Web, PDF, Tools, Samba, CUPS)
> **Hinweis:** HylaFAX und Asterisk Pakete kommen im separaten Block weiter unten.

```bash
sudo bash -euxo pipefail <<'EOF'
apt-get update

# Webserver + PHP + SQLite
apt-get install -y \
  apache2 \
  php \
  libapache2-mod-php \
  php-sqlite3 \
  sqlite3

# PDF-Tools (Merge/Report/Inspektion)
apt-get install -y \
  qpdf \
  ghostscript \
  poppler-utils

# ACL (für saubere Rechtevererbung)
apt-get install -y acl

# Samba + Clienttools (Shares)
apt-get install -y \
  samba \
  smbclient

# CUPS + Admin + Treiberbasis (für fax1..fax5 Drop-Drucker)
apt-get install -y \
  cups \
  cups-client

# Optional aber nützlich:
apt-get install -y \
  jq \
  curl

systemctl enable --now apache2
systemctl enable --now smbd || true
systemctl enable --now cups

EOF
```

---


## 4) Gruppe/Rechte (empfohlen: gemeinsame Gruppe `kienzlefax`)
Ziel: CUPS (`lp`), Apache (`www-data`), Worker (`faxworker`), Admin/User können zuverlässig schreiben/verschieben.

```bash
sudo bash -euxo pipefail <<'EOF'
# Gruppe anlegen
getent group kienzlefax >/dev/null || groupadd --system kienzlefax

# Users hinzufügen (falls existieren)
for u in lp www-data faxworker admin; do
  id "$u" >/dev/null 2>&1 && usermod -aG kienzlefax "$u" || true
done

# Optional: eigenen Login-User ergänzen
if id "$SUDO_USER" >/dev/null 2>&1; then
  usermod -aG kienzlefax "$SUDO_USER"
fi

# Ownership/Mode
chgrp -R kienzlefax /srv/kienzlefax
find /srv/kienzlefax -type d -exec chmod 2775 {} \;
find /srv/kienzlefax -type f -exec chmod 0664 {} \;

# ACL: Default-ACL für neue Dateien/Ordner
setfacl -R -m g:kienzlefax:rwx /srv/kienzlefax
setfacl -R -d -m g:kienzlefax:rwx /srv/kienzlefax
setfacl -R -d -m u::rwx /srv/kienzlefax
setfacl -R -d -m o::rx  /srv/kienzlefax

echo "Hinweis: Nach Gruppenänderungen neu einloggen (oder 'newgrp kienzlefax')."
EOF

```

## 5) Admin-User für Samba anlegen
> Der User `admin` wird als Systemuser + Samba-User erzeugt.

```bash
sudo bash -euxo pipefail <<'EOF'
# Systemuser admin (kein Shell-Login nötig; trotzdem robust)
if ! id admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash admin
fi

echo
echo "Jetzt Samba-Passwort für 'admin' setzen:"
smbpasswd -a admin

# Aktivieren (falls disabled)
smbpasswd -e admin || true
EOF
```


---

## 6) Samba-Shares (bestehende smb.conf erweitern)
> Fügt die Shares hinzu, ohne Drucker hier “neu” zu konfigurieren.

```bash
sudo bash -euxo pipefail <<'EOF'
SMB=/etc/samba/smb.conf
cp -a "$SMB" "${SMB}.bak.$(date +%Y%m%d-%H%M%S)"

# global: minimale sinnvolle Defaults (falls noch nicht vorhanden)
grep -q '^\[global\]' "$SMB" || cat >> "$SMB" <<'CFG'

[global]
   workgroup = WORKGROUP
   server string = kienzlefax samba
   security = user
   map to guest = Bad User

   # Printing über CUPS
   printing = cups
   printcap name = cups
   load printers = yes
CFG

# kienzlefax shares anhängen (falls nicht schon da)
grep -q '^\[pdf-zu-fax\]' "$SMB" || cat >> "$SMB" <<'CFG'

[pdf-zu-fax]
   path = /srv/kienzlefax/pdf-zu-fax
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   create mask = 0664
   directory mask = 2775

[sendefehler]
   path = /srv/kienzlefax/sendefehler
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   create mask = 0664
   directory mask = 2775

[sendeberichte]
   path = /srv/kienzlefax/sendeberichte
   browseable = yes
   read only = no
   valid users = admin
   force user = admin
   create mask = 0660
   directory mask = 2770

[webroot]
   path = /var/www/html/webroot
   browseable = yes
   read only = no
   valid users = admin
   force user = admin
   create mask = 0660
   directory mask = 2770
CFG

testparm -s
systemctl restart smbd || systemctl restart samba
EOF
```

## Drucker fax1..fax5 anlegen
```bash
sudo bash -euxo pipefail <<'EOF'
systemctl restart cups
sleep 1
lpstat -r

for i in 1 2 3 4 5; do
  mkdir -p "/srv/kienzlefax/incoming/fax$i"
done

MODEL="drv:///sample.drv/generic.ppd"

for i in 1 2 3 4 5; do
  PRN="fax$i"
  lpadmin -x "$PRN" 2>/dev/null || true
  lpadmin -p "$PRN" -E -v "kienzlefaxpdf:/$PRN" -m "$MODEL"
  lpadmin -p "$PRN" -o printer-is-shared=true
  cupsenable "$PRN"
  cupsaccept "$PRN"
done

systemctl restart cups
sleep 1
lpstat -p
lpstat -v | sed -n '1,120p'

lp -d fax1 /etc/hosts
sleep 3
ls -la /srv/kienzlefax/incoming/fax1 | tail -n 10
EOF
```

---

## 8) Web-UI & Worker installieren
> Diese beiden Artefakte wurden separat erstellt:
- `/var/www/html/kienzlefax.php`
- `/usr/local/bin/kienzlefax-worker.py` + systemd service

Die Installation erfolgt jeweils als pastebarer Block aus den entsprechenden Artefakten.

## 9) HylaFAX & Asterisk – notwendige Pakete (Basis)

### 9.1 HylaFAX
```bash
sudo bash -euxo pipefail <<'EOF'
apt-get update
apt-get install -y \
  hylafax-server \
  hylafax-client \
  faxstat \
  lsof

systemctl enable --now hylafax || true
systemctl enable --now hylafax-server || true

systemctl status hylafax* --no-pager || true
faxstat -s || true
EOF
```
### 9.2 Asterisk

- vielleicht läuift das so,. ich musste kompilieren!!! siehe 9.3 bzw. separate datei!!

```bash
sudo bash -euxo pipefail <<'EOF'
apt-get update
apt-get install -y asterisk
systemctl enable --now asterisk
systemctl status asterisk --no-pager
EOF
```

### 9.3. Astersik kompilieren

siehe separate .md-datei!

## 10) Troubleshooting Quick Checks

### 10.1-4 logs
```bash
CUPS Backend Log
sudo tail -n 200 /var/log/kienzlefaxpdf-backend.log

CUPS error_log
sudo tail -n 200 /var/log/cups/error_log

Worker Log
sudo journalctl -u kienzlefax-worker -n 200 --no-pager

HylaFAX Status
faxstat -s

```




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




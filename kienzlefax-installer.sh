#!/usr/bin/env bash
# ==============================================================================
# kienzlefax-installer.sh  (Raspberry Pi OS 13 / Debian 13)
#
# Version: 2.1
# Stand:   2026-02-17
#
# EIN-Datei-Installer (root-only, keine sudo-Aufrufe im Script).
#
# Was dieses Script tut:
#  1) Fragt am ANFANG die notwendigen Provider-Parameter ab:
#     - DynDNS/Public FQDN
#     - SIP Nummer (gleich Username)
#     - SIP Passwort (2× verdeckt)
#     - optional: FAX DID (Default = SIP Nummer)
#     - AMI Secret für lokalen Asterisk-Manager (2× verdeckt)
#  2) apt-get update + apt-get -y upgrade
#  3) Installiert Pakete gebündelt am Anfang (OHNE HylaFAX, OHNE iaxmodem)
#  4) Installiert Web (kienzlefax.php + faxton.mp3)
#  5) Legt User admin (Login + sudo) an und fragt Passwörter ab (Linux 2×, Samba 2×)
#  6) Installiert CUPS Backend + fax1..fax5 + Bonjour/DNS-SD + Samba Shares (inkl. fax-eingang)
#  7) Baut SpanDSP + Asterisk (INTERAKTIV: make menuselect)
#  8) Ganz am ENDE: schreibt Asterisk-Configs:
#     - rtp.conf, pjsip.conf
#     - manager.conf (robust, minimal-invasiv, bindaddr=127.0.0.1, enabled=yes)
#     - manager.d/kfx.conf (lokal only)
#     - extensions.conf (NEUE Vorlage: send_start/dial_end/send_end + Hangup-Handler)
#     - installiert AGI (kfx_update_status.agi v1.3.6)
#     - installiert Worker (kienzlefax-worker.py v1.3.5) + systemd service
#  9) Ganz am ENDE: erstellt /usr/local/bin/pdf_with_header.sh (Header je Seite)
#
# INTERAKTIV:
#  - SIP Passwort (2×)
#  - AMI Secret (2×)
#  - Linux admin Passwort (passwd)
#  - Samba admin Passwort (smbpasswd)
#  - make menuselect
#
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

require_root(){
  [[ ${EUID:-0} -eq 0 ]] || die "Bitte als root ausführen."
}

svc_exists(){
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

svc_enable_now(){
  local u="$1"
  if svc_exists "$u"; then
    systemctl enable --now "$u"
    log "[OK] enabled+started: $u"
  else
    log "[INFO] unit not found (skip): $u"
  fi
}

read_secret_twice(){
  # usage: read_secret_twice "Prompt" VAR_NAME
  local prompt="$1"
  local __var="$2"
  local a b
  while true; do
    read -r -s -p "${prompt} (Eingabe 1/2): " a; echo
    read -r -s -p "${prompt} (Eingabe 2/2): " b; echo
    [[ -n "${a}" ]] || { echo "Darf nicht leer sein."; continue; }
    [[ "${a}" == "${b}" ]] || { echo "Stimmt nicht überein. Bitte erneut."; continue; }
    printf -v "${__var}" "%s" "${a}"
    unset a b
    break
  done
}

sanitize_digits(){
  echo "$1" | tr -cd '0-9'
}

backup_file_ts(){
  # usage: backup_file_ts /path/to/file
  local f="$1"
  local stamp=".old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}${stamp}"
    log "backup: $f -> ${f}${stamp}"
  fi
}

# ------------------------------------------------------------------------------
# Preconditions + Parameterabfrage (GANZ AM ANFANG)
# ------------------------------------------------------------------------------
require_root
export DEBIAN_FRONTEND=noninteractive

sep "Provider-Parameter abfragen (DynDNS/FQDN, SIP Nummer, SIP Passwort, FAX DID, AMI Secret)"

read -r -p "DynDNS / Public FQDN (z.B. myhost.dyndns.org): " PUBLIC_FQDN
[[ -n "${PUBLIC_FQDN}" ]] || die "PUBLIC_FQDN darf nicht leer sein."

read -r -p "SIP Nummer (gleich Username, nur Ziffern, z.B. 4923...): " SIP_NUMBER_RAW
SIP_NUMBER="$(sanitize_digits "${SIP_NUMBER_RAW}")"
[[ -n "${SIP_NUMBER}" ]] || die "SIP Nummer ist leer/ungültig."
unset SIP_NUMBER_RAW

read_secret_twice "SIP Passwort" SIP_PASSWORD

read -r -p "FAX DID (Enter = ${SIP_NUMBER}): " FAX_DID_IN
FAX_DID="$(sanitize_digits "${FAX_DID_IN:-$SIP_NUMBER}")"
[[ -n "${FAX_DID}" ]] || die "FAX_DID darf nicht leer sein."
unset FAX_DID_IN

echo
echo "AMI (Asterisk Manager) läuft NUR lokal auf 127.0.0.1:5038. Bitte Secret setzen:"
read_secret_twice "AMI Secret (User kfx)" AMI_SECRET

log "[OK] Parameter gesetzt:"
log " - PUBLIC_FQDN=${PUBLIC_FQDN}"
log " - SIP_NUMBER=${SIP_NUMBER}"
log " - FAX_DID=${FAX_DID}"
log " - AMI: 127.0.0.1:5038 user=kfx (secret gesetzt)"

# ------------------------------------------------------------------------------
# Konstanten / URLs
# ------------------------------------------------------------------------------
KZ_BASE="/srv/kienzlefax"
KZ_WEBROOT="/var/www/html"
KZ_WEBROOT_ADMIN="${KZ_WEBROOT}/webroot"

WEB_URL="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/kienzlefax.php"
FAXTON_URL="https://github.com/thomaskien/kienzlefax-fuer-linux/raw/refs/heads/main/faxton.mp3"

# Asterisk Build Version (bewusst fixiert)
ASTERISK_VER="20.18.2"
ASTERISK_TGZ="asterisk-${ASTERISK_VER}.tar.gz"
ASTERISK_URL="http://downloads.asterisk.org/pub/telephony/asterisk/${ASTERISK_TGZ}"

# SpanDSP (Freeswitch fork)
SPANDSP_GIT="https://github.com/freeswitch/spandsp.git"

# Asterisk runtime dirs for fax-in
SPOOL_TIFF_DIR="/var/spool/asterisk/fax1"
SPOOL_PDF_DIR="/var/spool/asterisk/fax"

# ------------------------------------------------------------------------------
# 1) apt update/upgrade + Pakete gebündelt
# ------------------------------------------------------------------------------
sep "System aktualisieren + Pakete installieren (gebündelt, OHNE HylaFAX, OHNE iaxmodem)"

apt-get update
apt-get -y upgrade

apt-get install -y --no-install-recommends \
  ca-certificates curl wget jq \
  acl lsof coreutils iproute2 \
  apache2 libapache2-mod-php \
  php php-cli php-sqlite3 php-mbstring sqlite3 \
  qpdf ghostscript poppler-utils libtiff-tools \
  cups cups-client \
  avahi-daemon avahi-utils \
  samba smbclient sudo \
  python3 python3-reportlab \
  build-essential git pkg-config autoconf automake libtool \
  libxml2-dev libncurses5-dev libedit-dev uuid-dev \
  libssl-dev libsqlite3-dev \
  libsrtp2-dev \
  libtiff-dev \
  libjansson-dev

# PyPDF/PyPDF2: je nach Debian/RPi OS unterschiedlich benannt
set +e
apt-get install -y --no-install-recommends python3-pypdf >/dev/null 2>&1
rc1=$?
apt-get install -y --no-install-recommends python3-pypdf2 >/dev/null 2>&1
rc2=$?
set -e
if [[ $rc1 -ne 0 && $rc2 -ne 0 ]]; then
  die "Konnte weder python3-pypdf noch python3-pypdf2 installieren. Bitte Paketname prüfen."
fi

log "[OK] Pakete installiert."

# ------------------------------------------------------------------------------
# 2) Verzeichnisse (ABGLEICH wie gewünscht) + Gruppe + Grund-ACL
# ------------------------------------------------------------------------------
sep "Basis-Verzeichnisse + Gruppe/ACL (inkl. staging/queue/processing, sendefehler split)"

# Basis
mkdir -p "${KZ_BASE}"

# Eingänge (Drucker)
for i in 1 2 3 4 5; do
  mkdir -p "${KZ_BASE}/incoming/fax${i}"
done

# Drop-ins
mkdir -p "${KZ_BASE}/pdf-zu-fax"
mkdir -p "${KZ_BASE}/sendefehler/eingang"
mkdir -p "${KZ_BASE}/sendefehler/berichte"

# Queue-Layer
mkdir -p "${KZ_BASE}/staging"
mkdir -p "${KZ_BASE}/queue"
mkdir -p "${KZ_BASE}/processing"

# Archiv
mkdir -p "${KZ_BASE}/sendeberichte"

# Telefonbuch-DB Platzhalter
touch "${KZ_BASE}/phonebook.sqlite"

# Optional: Webroot (admin-only Share)
mkdir -p "${KZ_WEBROOT_ADMIN}"

# Gruppe
getent group kienzlefax >/dev/null || groupadd --system kienzlefax

# Users (falls existieren) in Gruppe
for u in lp www-data admin; do
  id "$u" >/dev/null 2>&1 && usermod -aG kienzlefax "$u" || true
done

# Grundrechte (bewusstes Design)
chown -R root:kienzlefax "${KZ_BASE}"

chmod 2775 "${KZ_BASE}"
chmod 2777 "${KZ_BASE}/incoming"
chmod 2777 "${KZ_BASE}/incoming"/fax{1..5}

chmod 2777 "${KZ_BASE}/pdf-zu-fax"
chmod 2777 "${KZ_BASE}/sendefehler"
chmod 2777 "${KZ_BASE}/sendefehler/eingang"
chmod 2777 "${KZ_BASE}/sendefehler/berichte"

chmod 2775 "${KZ_BASE}/staging" "${KZ_BASE}/queue" "${KZ_BASE}/processing"
chmod 2770 "${KZ_BASE}/sendeberichte"

# ACL: lp + gruppe dürfen in incoming schreiben
setfacl -m u:lp:rwx,g:kienzlefax:rwx "${KZ_BASE}/incoming" "${KZ_BASE}/incoming"/fax{1..5} || true
setfacl -d -m u:lp:rwx,g:kienzlefax:rwx "${KZ_BASE}/incoming" "${KZ_BASE}/incoming"/fax{1..5} || true

# Default ACL im Base (praktisch)
setfacl -R -m g:kienzlefax:rwx "${KZ_BASE}" || true
setfacl -R -d -m g:kienzlefax:rwx "${KZ_BASE}" || true

log "[OK] Verzeichnisse/Rechte/ACL erledigt."

# ------------------------------------------------------------------------------
# 3) Admin-Account (Login + sudo + Samba) – interaktiv
# ------------------------------------------------------------------------------
sep "Admin-Account anlegen (Login + sudo + Samba)"

if ! id admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash admin
  log "[OK] User 'admin' angelegt."
else
  log "[OK] User 'admin' existiert bereits."
fi

usermod -aG sudo admin
log "[OK] 'admin' ist in Gruppe 'sudo'."

echo
echo "==== Linux-Login-Passwort für 'admin' setzen (2× Eingabe) ===="
passwd admin

echo
echo "==== Samba-Passwort für 'admin' setzen (2× Eingabe) ===="
echo "HINWEIS: Wenn du EIN Passwort für alles willst, gib hier dasselbe Passwort ein wie oben."
smbpasswd -a admin
smbpasswd -e admin || true
log "[OK] Samba-User 'admin' aktiviert."

# ------------------------------------------------------------------------------
# 4) Web installieren (kienzlefax.php + faxton.mp3) + Apache starten
# ------------------------------------------------------------------------------
sep "kienzlefax Web installieren (kienzlefax.php + faxton.mp3)"

mkdir -p "${KZ_WEBROOT}"
curl -fsSL -o "${KZ_WEBROOT}/kienzlefax.php" "${WEB_URL}"
curl -fsSL -o "${KZ_WEBROOT}/faxton.mp3" "${FAXTON_URL}"

chown www-data:www-data "${KZ_WEBROOT}/kienzlefax.php" "${KZ_WEBROOT}/faxton.mp3" || true
chmod 0644 "${KZ_WEBROOT}/kienzlefax.php" "${KZ_WEBROOT}/faxton.mp3"

svc_enable_now apache2.service
systemctl restart apache2 || true

log "[OK] Web installiert: ${KZ_WEBROOT}/kienzlefax.php"

# ------------------------------------------------------------------------------
# 5) Appliance-Teil (CUPS Backend + fax1..fax5 + Bonjour + Samba Shares)
# ------------------------------------------------------------------------------
sep "CUPS Backend + fax1..fax5 + Bonjour + Samba Shares (inkl. fax-eingang)"

WORKGROUP="WORKGROUP"
SAMBA_ADMIN_USER="admin"

INCOMING="${KZ_BASE}/incoming"
PDF_ZU_FAX="${KZ_BASE}/pdf-zu-fax"
SENDEFEHLER_EINGANG="${KZ_BASE}/sendefehler/eingang"
SENDEFEHLER_BERICHTE="${KZ_BASE}/sendefehler/berichte"
SENDEBERICHTE="${KZ_BASE}/sendeberichte"

BACKEND="/usr/lib/cups/backend/kienzlefaxpdf"
BACKEND_LOG="/var/log/kienzlefaxpdf-backend.log"

echo "== cups-browsed deaktivieren (falls vorhanden; verhindert implicitclass://) =="
if svc_exists cups-browsed.service; then
  systemctl stop cups-browsed || true
  systemctl disable cups-browsed || true
fi

echo "== Backend installieren (deterministisch) =="
cat > "$BACKEND" <<'BACKEND_EOF'
#!/bin/bash
set -u  # KEIN set -e, wir loggen Fehler selbst

DESTBASE="/srv/kienzlefax/incoming"
LOG="/var/log/kienzlefaxpdf-backend.log"

TIMEOUT="/usr/bin/timeout"
GS="/usr/bin/gs"
MKTEMP="/usr/bin/mktemp"
STAT="/usr/bin/stat"
MV="/bin/mv"
CHMOD="/bin/chmod"
MKDIR="/bin/mkdir"
DATE="/usr/bin/date"
TR="/usr/bin/tr"
SED="/usr/bin/sed"

CUPSTMP="/var/spool/cups/tmp"
TMPBASE="/tmp"
if [[ -d "$CUPSTMP" && -w "$CUPSTMP" ]]; then
  TMPBASE="$CUPSTMP"
fi

log() { echo "[$($DATE -Is)] $*" >> "$LOG"; }

if [[ $# -eq 0 ]]; then
  echo 'direct kienzlefaxpdf "KienzleFax PDF Drop (fax1..fax5)" "kienzlefaxpdf:/fax1"'
  echo 'direct kienzlefaxpdf "KienzleFax PDF Drop (fax1..fax5)" "kienzlefaxpdf:/fax2"'
  echo 'direct kienzlefaxpdf "KienzleFax PDF Drop (fax1..fax5)" "kienzlefaxpdf:/fax3"'
  echo 'direct kienzlefaxpdf "KienzleFax PDF Drop (fax1..fax5)" "kienzlefaxpdf:/fax4"'
  echo 'direct kienzlefaxpdf "KienzleFax PDF Drop (fax1..fax5)" "kienzlefaxpdf:/fax5"'
  exit 0
fi

JOBID="${1:-}"
USER="${2:-unknown}"
TITLE="${3:-job}"
COPIES="${4:-1}"
FILE="${6:-}"
URI="${DEVICE_URI:-}"
PRN="${URI#kienzlefaxpdf:/}"
PRN="${PRN%%/*}"

log "START jobid=$JOBID user=$USER title=$TITLE copies=$COPIES file='${FILE:-}' uri='$URI' prn='$PRN' tmpbase='$TMPBASE'"

if [[ -z "$JOBID" ]]; then log "ERROR: missing jobid"; exit 1; fi
if [[ ! "$PRN" =~ ^fax[1-5]$ ]]; then log "ERROR: invalid prn '$PRN'"; exit 1; fi

OUTDIR="$DESTBASE/$PRN"
if ! $MKDIR -p "$OUTDIR"; then log "ERROR: mkdir '$OUTDIR' failed"; exit 1; fi

ts="$($DATE +%Y%m%d-%H%M%S)"
base="$(echo "$TITLE" | $TR -c 'A-Za-z0-9._-' '_' | $SED 's/^_//;s/_$//')"
base="${base:-print}"
out="$OUTDIR/${ts}__${PRN}__${USER}__${base}__${JOBID}.pdf"

tmp_in=""
if [[ -n "${FILE:-}" && -f "$FILE" ]]; then
  infile="$FILE"
else
  tmp_in="$($MKTEMP --tmpdir="$TMPBASE" "kienzlefaxpdf.${JOBID}.XXXXXX" 2>/dev/null)"
  if [[ -z "$tmp_in" ]]; then
    log "ERROR: mktemp stdin file failed (tmpbase=$TMPBASE)"
    exit 1
  fi
  cat > "$tmp_in"
  infile="$tmp_in"
fi

size="$($STAT -c%s "$infile" 2>/dev/null || echo '?')"
log "INFO: infile='$infile' size=$size"

tmp_pdf="$($MKTEMP --tmpdir="$TMPBASE" "kienzlefaxpdf.${JOBID}.XXXXXX.pdf" 2>/dev/null)"
if [[ -z "$tmp_pdf" ]]; then
  log "ERROR: mktemp pdf failed (tmpbase=$TMPBASE)"
  [[ -n "$tmp_in" ]] && rm -f "$tmp_in" || true
  exit 1
fi

log "INFO: gs begin -> '$tmp_pdf'"

export TMPDIR="$TMPBASE"

if ! $TIMEOUT 60s $GS -q -dSAFER -dBATCH -dNOPAUSE \
  -sDEVICE=pdfwrite -sOutputFile="$tmp_pdf" "$infile" >>"$LOG" 2>&1; then
  rc=$?
  log "ERROR: gs failed/timeout rc=$rc"
  rm -f "$tmp_pdf" || true
  [[ -n "$tmp_in" ]] && rm -f "$tmp_in" || true
  exit 1
fi

outsize="$($STAT -c%s "$tmp_pdf" 2>/dev/null || echo '?')"
log "INFO: gs ok size=$outsize"

if ! $MV -f "$tmp_pdf" "$out"; then
  log "ERROR: mv failed to '$out'"
  rm -f "$tmp_pdf" || true
  [[ -n "$tmp_in" ]] && rm -f "$tmp_in" || true
  exit 1
fi

$CHMOD 0664 "$out" || true
[[ -n "$tmp_in" ]] && rm -f "$tmp_in" || true

log "OK wrote '$out'"
exit 0
BACKEND_EOF

chmod 0755 "$BACKEND"
chown root:root "$BACKEND"

echo "== Backend-Logfile vorbereiten (schreibbar für CUPS/lp) =="
touch "$BACKEND_LOG"
chown lp:lp "$BACKEND_LOG" || true
chmod 0664 "$BACKEND_LOG"

echo "== CUPS: Bonjour/DNS-SD aktivieren (minimal) =="
CUPSD="/etc/cups/cupsd.conf"
if grep -qE '^[#[:space:]]*Browsing[[:space:]]+' "$CUPSD"; then
  sed -i -E 's/^[#[:space:]]*Browsing[[:space:]]+.*/Browsing On/' "$CUPSD"
else
  echo 'Browsing On' >> "$CUPSD"
fi
if grep -qE '^[#[:space:]]*BrowseLocalProtocols[[:space:]]+' "$CUPSD"; then
  sed -i -E 's/^[#[:space:]]*BrowseLocalProtocols[[:space:]]+.*/BrowseLocalProtocols dnssd/' "$CUPSD"
else
  echo 'BrowseLocalProtocols dnssd' >> "$CUPSD"
fi
cupsctl --share-printers >/dev/null 2>&1 || true

echo "== CUPS: fax1..fax5 deterministisch anlegen =="
for i in 1 2 3 4 5; do
  lpadmin -x "fax$i" 2>/dev/null || true
done
for i in 1 2 3 4 5; do
  PRN="fax$i"
  lpadmin -p "$PRN" -E -v "kienzlefaxpdf:/$PRN" -m raw
  lpadmin -p "$PRN" -o printer-is-shared=true
  lpadmin -p "$PRN" -o media=A4
  cupsenable "$PRN"
  cupsaccept "$PRN"
done

echo "== Samba: minimale smb.conf schreiben (inkl. Shares) =="
mkdir -p /var/spool/samba
chmod 1777 /var/spool/samba

# fax-eingang path sicherstellen (Guest share)
mkdir -p "${SPOOL_PDF_DIR}"
chmod 0777 "${SPOOL_PDF_DIR}" || true

cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = ${WORKGROUP}
   server string = kienzlefax samba
   security = user
   map to guest = Bad User
   guest account = nobody
   server min protocol = SMB2
   smb ports = 445

   # Printing via CUPS
   printing = cups
   printcap name = cups
   load printers = yes
   disable spoolss = yes

[printers]
   comment = All Printers
   path = /var/spool/samba
   printable = yes
   browseable = yes
   guest ok = yes
   read only = yes
   create mask = 0700

### KIENZLEFAX SHARES BEGIN ###

[pdf-zu-fax]
   path = ${PDF_ZU_FAX}
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0666
   directory mask = 2777

[sendefehler-eingang]
   path = ${SENDEFEHLER_EINGANG}
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0666
   directory mask = 2777

[sendefehler-berichte]
   path = ${SENDEFEHLER_BERICHTE}
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0666
   directory mask = 2777

[sendeberichte]
   path = ${SENDEBERICHTE}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SAMBA_ADMIN_USER}
   write list = ${SAMBA_ADMIN_USER}
   create mask = 0660
   directory mask = 2770

[webroot]
   force group = www-data
   force user = www-data
   path = /var/www/html
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SAMBA_ADMIN_USER}
   write list = ${SAMBA_ADMIN_USER}
   create mask = 0660
   directory mask = 2770

[fax-eingang]
   path = ${SPOOL_PDF_DIR}
   browseable = yes
   writable = yes
   read only = no
   guest ok = yes
   public = yes
   create mask = 0777
   directory mask = 0777
   force user = nobody
   force group = nogroup

### KIENZLEFAX SHARES END ###
EOF

# Webroot wirklich schreibbar für www-data (damit Samba-Share funktioniert)
chown -R www-data:www-data /var/www/html || true
chmod 2775 /var/www/html || true

echo "== Dienste neu starten/aktivieren =="
systemctl enable cups avahi-daemon smbd >/dev/null 2>&1 || true
systemctl restart avahi-daemon || true
systemctl restart cups
systemctl restart smbd || true
systemctl restart nmbd 2>/dev/null || true

echo
echo "== Quick Checks =="
echo "-- CUPS --"
lpstat -r || true
lpstat -v || true

echo
echo "-- Testdruck (fax1) -> sollte PDF in incoming/fax1 erzeugen --"
rm -f "${INCOMING}/fax1"/*.pdf 2>/dev/null || true
lp -d fax1 /etc/hosts || true
sleep 2
ls -la "${INCOMING}/fax1" | tail -n 20 || true

echo
echo "-- Backend Log tail --"
tail -n 30 "$BACKEND_LOG" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 6) SpanDSP bauen/installieren
# ------------------------------------------------------------------------------
sep "SpanDSP bauen/installieren"

mkdir -p /usr/src
cd /usr/src

if [[ ! -d spandsp ]]; then
  git clone "${SPANDSP_GIT}" spandsp
else
  log "[INFO] /usr/src/spandsp existiert bereits (skip clone)."
fi

cd /usr/src/spandsp
./bootstrap.sh
./configure
make -j"$(nproc)"
make install
ldconfig

# ------------------------------------------------------------------------------
# 7) Asterisk bauen/installieren (INTERAKTIV: menuselect)
# ------------------------------------------------------------------------------
sep "Asterisk ${ASTERISK_VER} bauen/installieren (INTERAKTIV: make menuselect)"

cd /usr/src
if [[ ! -f "${ASTERISK_TGZ}" ]]; then
  wget -O "${ASTERISK_TGZ}" "${ASTERISK_URL}"
else
  log "[INFO] ${ASTERISK_TGZ} existiert bereits (skip download)."
fi

rm -rf "asterisk-${ASTERISK_VER}"
tar xzf "${ASTERISK_TGZ}"
cd "asterisk-${ASTERISK_VER}"

contrib/scripts/get_mp3_source.sh || true
./configure

echo
echo "======================================================================"
echo "INTERAKTIV: Jetzt öffnet sich menuselect."
echo "Bitte die benötigten Module/Optionen aktivieren und dann speichern/beenden."
echo "Hinweis: Für Fax per SendFAX müssen die Fax-/Spandsp-Module aktiv sein."
echo "======================================================================"
echo
make menuselect

make -j"$(nproc)"
make install
make samples
make config
ldconfig

# ------------------------------------------------------------------------------
# 8) Ganz am Ende: Asterisk-Config Bootstrap (rtp/pjsip/manager/extensions) + AGI + Worker
# ------------------------------------------------------------------------------
sep "GANZ AM ENDE: Asterisk-Konfiguration + AMI lokal + Dialplan + AGI + Worker"

# ---- 8.1) Backups relevanter Dateien (timestamp) ----
for f in \
  /etc/asterisk/rtp.conf \
  /etc/asterisk/pjsip.conf \
  /etc/asterisk/manager.conf \
  /etc/asterisk/extensions.conf
do
  [[ -e "$f" ]] && backup_file_ts "$f" || true
done

# ---- 8.2) Spool-Verzeichnisse + Rechte ----
mkdir -p "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}"
if id asterisk >/dev/null 2>&1; then
  chown -R asterisk:asterisk "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}" || true
fi
chmod 0755 "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}" || true

# ---- 8.3) /etc/asterisk/rtp.conf schreiben ----
cat >/etc/asterisk/rtp.conf <<EOF
[general]
rtpstart=12000
rtpend=12049
icesupport=no
strictrtp=yes
EOF

# ---- 8.4) /etc/asterisk/pjsip.conf schreiben ----
# minimal, wie dein Stand – Provider 1und1, bind 0.0.0.0:5070, external via FQDN
cat >/etc/asterisk/pjsip.conf <<EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5070

external_signaling_address = ${PUBLIC_FQDN}
external_media_address     = ${PUBLIC_FQDN}

local_net = 10.0.0.0/8
local_net = 192.168.0.0/16

[1und1]
type=registration
transport=transport-udp
outbound_auth=1und1-auth
server_uri=sip:sip.1und1.de
client_uri=sip:${SIP_NUMBER}@sip.1und1.de
contact_user=${SIP_NUMBER}
retry_interval=60
forbidden_retry_interval=600
expiration=300

[1und1-auth]
type=auth
auth_type=userpass
username=${SIP_NUMBER}
password=${SIP_PASSWORD}

[1und1-aor]
type=aor
contact=sip:sip.1und1.de

[1und1-endpoint]
type=endpoint
transport=transport-udp
context=fax-in
disallow=all
allow=alaw,ulaw
outbound_auth=1und1-auth
aors=1und1-aor
direct_media=no
rewrite_contact=yes
rtp_symmetric=yes
force_rport=yes

t38_udptl=no
t38_udptl_nat=no

from_user=${SIP_NUMBER}
from_domain=sip.1und1.de

send_pai=yes
send_rpid=yes
trust_id_outbound=yes

[1und1-identify]
type=identify
endpoint=1und1-endpoint
match=212.227.0.0/16
EOF

# ---- 8.5) AMI (manager.conf) robust sicherstellen + manager.d/kfx.conf ----
MANAGER_CONF="/etc/asterisk/manager.conf"
mkdir -p /etc/asterisk/manager.d

# include manager.d sicherstellen (genau wie gewünscht)
if ! grep -qE '^\s*#include\s+"/etc/asterisk/manager\.d/\*\.conf"\s*$' "${MANAGER_CONF}" 2>/dev/null; then
  echo '#include "/etc/asterisk/manager.d/*.conf"' >> "${MANAGER_CONF}"
fi

# helper: set or add key within [general] (minimal-invasiv)
ensure_manager_general_key(){
  local key="$1" val="$2"
  # gibt es [general]?
  if ! grep -qE '^\s*\[general\]\s*$' "${MANAGER_CONF}" 2>/dev/null; then
    cat >> "${MANAGER_CONF}" <<EOF

[general]
enabled = yes
webenabled = no
bindaddr = 127.0.0.1
port = 5038
EOF
    return 0
  fi

  # innerhalb [general] key setzen/ergänzen
  # 1) key existiert in [general] -> ersetzen
  if awk -v k="$key" '
    BEGIN{in=0;found=0}
    /^\s*\[general\]\s*$/ {in=1; next}
    /^\s*\[/ {if(in){exit} }
    { if(in && $0 ~ "^[[:space:]]*"k"[[:space:]]*=") {found=1; exit} }
    END{ exit(found?0:1) }
  ' "${MANAGER_CONF}"; then
    # ersetze nur innerhalb [general]
    perl -0777 -pe '
      my ($k,$v)=@ARGV;
      s/(\[general\][^\[]*?)^\s*\Q$k\E\s*=.*?$/$1$k = $v/mgse;
    ' "$key" "$val" -i "${MANAGER_CONF}"
  else
    # 2) key fehlt in [general] -> nach [general]-Zeile einfügen (oder ans Ende des blocks)
    perl -0777 -pe '
      my ($k,$v)=@ARGV;
      s/(\[general\]\s*\n)/$1$k = $v\n/s;
    ' "$key" "$val" -i "${MANAGER_CONF}"
  fi
}

ensure_manager_general_key "enabled"   "yes"
ensure_manager_general_key "webenabled" "no"
ensure_manager_general_key "bindaddr"  "127.0.0.1"
ensure_manager_general_key "port"      "5038"

# kfx user (lokal) + secret
cat >/etc/asterisk/manager.d/kfx.conf <<EOF
[kfx]
secret = ${AMI_SECRET}

; nur lokal (weil AMI bindaddr=127.0.0.1)
deny=0.0.0.0/0.0.0.0
permit=127.0.0.1/255.255.255.255

read = system,call,log,command,reporting
write = system,call,command,reporting,originate
EOF
chmod 0644 /etc/asterisk/manager.d/kfx.conf
chown root:root /etc/asterisk/manager.d/kfx.conf

# ---- 8.6) extensions.conf (NEUE Vorlage) schreiben + dialplan reload ----
CONF="/etc/asterisk/extensions.conf"
STAMP=".old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONF" "${CONF}${STAMP}" 2>/dev/null || true

# Vorlage: wie gepastet, aber Nummern dynamisch befüllt:
# - fax-in exten => ${FAX_DID}
# - CALLERID(num) => ${SIP_NUMBER}
cat >"$CONF" <<EOF
[general]
static=yes
writeprotect=no
clearglobalvars=no

; =============================================================================
; kienzlefax — Asterisk Dialplan
; - Fax-Out: Dial() + SendFAX() im callee Gosub
; - Status/Result "Quelle der Wahrheit": kfx_update_status.agi (send_start / dial_end / send_end)
; - Robust: Hangup-Handler auf PJSIP-Kanal als Fallback (weil FAX* Variablen dort gültig sind)
;
; WICHTIG:
; - Der Worker originiert via AMI auf: Local/<exten>@fax-out/n und hält den Originate-Channel per Wait lange genug.
; - DIALSTATUS=CANCEL + HANGUPCAUSE=19 wird im AGI als NOANSWER behandelt (Retry 3x).
; =============================================================================


; =============================================================================
; FAX-OUT
; =============================================================================
[fax-out]

; --- falls Datei fehlt ---
exten => kfx_missing_file,1,NoOp(FAX OUT ERROR: missing KFX_FILE | jobid=\${KFX_JOBID})
 same => n,AGI(kfx_update_status.agi,\${KFX_JOBID},dial_end,CHANUNAVAIL,0)
 same => n,Hangup()

; --- h-extension: wird bei Hangup des Local-Channels ausgeführt ---
; Nicht mit Return() enden (kein Gosub-Stack!). Einfach Hangup.
exten => h,1,NoOp(fax-out h-extension | jobid=\${KFX_JOBID} DIALSTATUS=\${DIALSTATUS} HANGUPCAUSE=\${HANGUPCAUSE})
 ; Dial-End immer melden (aber: wenn ANSWER, finalisiert AGI NICHT, sondern wartet auf send_end/hangup)
 same => n,AGI(kfx_update_status.agi,\${KFX_JOBID},dial_end,\${DIALSTATUS},\${HANGUPCAUSE})
 same => n,Hangup()

; --- 49... -> 0... ---
exten => _49X.,1,NoOp(FAX OUT normalize 49... -> national | jobid=\${KFX_JOBID} file=\${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,Set(NORM=0\${EXTEN:2})
 same => n,NoOp(NORMALIZED=\${NORM})
 same => n,GotoIf(\$[ "\${KFX_FILE}" = "" ]?kfx_missing_file,1)

 ; Job-Tagging (wichtig für Cancel/Orphan-Reconcile)
 same => n,Set(CHANNEL(accountcode)=\${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:\${KFX_JOBID})

 ; Fax-Optionen
 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 ; CallerID
 same => n,Set(CALLERID(num)=${SIP_NUMBER})
 same => n,Set(CALLERID(name)=Fax)

 ; Dial: callee Gosub führt SendFAX auf PJSIP-Kanal aus
 ; g = weiter im Dialplan nach Auflegen
 ; U() = Gosub auf callee channel (PJSIP), dort sind FAX* gültig
 same => n,Dial(PJSIP/\${NORM}@1und1-endpoint,60,gU(kfx_sendfax^\${KFX_JOBID}^\${KFX_FILE}))
 same => n,Hangup()

; --- national 0... ---
exten => _0X.,1,NoOp(FAX OUT national | jobid=\${KFX_JOBID} file=\${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,GotoIf(\$[ "\${KFX_FILE}" = "" ]?kfx_missing_file,1)

 same => n,Set(CHANNEL(accountcode)=\${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:\${KFX_JOBID})

 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 same => n,Set(CALLERID(num)=${SIP_NUMBER})
 same => n,Set(CALLERID(name)=Fax)

 same => n,Dial(PJSIP/\${EXTEN}@1und1-endpoint,60,gU(kfx_sendfax^\${KFX_JOBID}^\${KFX_FILE}))
 same => n,Hangup()


; =============================================================================
; CALLEE GOSUB: SendFAX läuft auf dem PJSIP-Kanal
; =============================================================================
[kfx_sendfax]
exten => s,1,NoOp(kfx_sendfax | jobid=\${ARG1} file=\${ARG2} chan=\${CHANNEL(name)})

 ; Job-Tagging auch auf PJSIP-Kanal
 same => n,Set(CHANNEL(accountcode)=\${ARG1})
 same => n,Set(CDR(userfield)=kfx:\${ARG1})

 ; Fallback: Hangup-Handler auf PJSIP-Kanal (FAX* Variablen hier noch vorhanden)
 same => n,Set(CHANNEL(hangup_handler_push)=kfx_sendfax_hangup,s,1(\${ARG1}))

 ; send_start: status=sending + channel/uniqueid ins job.json
 same => n,AGI(kfx_update_status.agi,\${ARG1},send_start)

 ; Der eigentliche Faxversand
 same => n,TryExec(SendFAX(\${ARG2}))

 ; Wichtig: nach SendFAX sind FAX* Variablen hier gültig (PJSIP-Kanal)
 same => n,NoOp(FAX done | FAXSTATUS=\${FAXSTATUS} FAXERROR=\${FAXERROR} FAXPAGES=\${FAXPAGES} FAXBITRATE=\${FAXBITRATE} FAXECM=\${FAXECM} DIALSTATUS=\${DIALSTATUS} HANGUPCAUSE=\${HANGUPCAUSE})

 ; send_end: Quelle der Wahrheit (entscheidet OK/RETRY/FAILED nach Policy)
 same => n,AGI(kfx_update_status.agi,\${ARG1},send_end,\${FAXSTATUS},\${FAXERROR},\${FAXPAGES},\${FAXBITRATE},\${FAXECM},\${DIALSTATUS},\${HANGUPCAUSE})

 same => n,Return()


; =============================================================================
; Hangup Handler auf PJSIP-Kanal (Fallback, falls send_end nicht lief)
; =============================================================================
[kfx_sendfax_hangup]
exten => s,1,NoOp(kfx_sendfax_hangup | jobid=\${ARG1} chan=\${CHANNEL(name)} FAXSTATUS=\${FAXSTATUS} FAXERROR=\${FAXERROR} FAXPAGES=\${FAXPAGES} FAXBITRATE=\${FAXBITRATE} FAXECM=\${FAXECM} DIALSTATUS=\${DIALSTATUS} HANGUPCAUSE=\${HANGUPCAUSE})
 ; Nur sinnvoll, wenn nicht schon SUCCESS/OK in job.json steht – diese Logik macht das AGI konservativ.
 same => n,AGI(kfx_update_status.agi,\${ARG1},send_end,\${FAXSTATUS},\${FAXERROR},\${FAXPAGES},\${FAXBITRATE},\${FAXECM},\${DIALSTATUS},\${HANGUPCAUSE})
 same => n,Return()


; =============================================================================
; FAX-IN (UID nur Zähler-Teil nach Punkt)
; =============================================================================
[fax-in]
exten => ${FAX_DID},1,NoOp(Inbound Fax)
 same => n,Answer()
 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,Set(JITTERBUFFER(adaptive)=default)

 same => n,Set(FAXSTAMP=\${STRFTIME(\${EPOCH},,%Y%m%d-%H%M%S)})
 same => n,Set(FROMRAW=\${CALLERID(num)})
 same => n,Set(FROM=\${FILTER(0-9,\${FROMRAW})})
 same => n,ExecIf(\$["\${FROM}"=""]?Set(FROM=unknown))

 ; UNIQUEID nur Zähler-Teil nach Punkt
 same => n,Set(UID=\${CUT(UNIQUEID,.,2)})
 same => n,ExecIf(\$["\${UID}"=""]?Set(UID=\${UNIQUEID}))

 same => n,Set(FAXBASE=\${FAXSTAMP}_\${FROM}_\${UID})
 same => n,Set(TIFF=${SPOOL_TIFF_DIR}/\${FAXBASE}.tif)
 same => n,Set(PDF=${SPOOL_PDF_DIR}/\${FAXBASE}.pdf)

 same => n,ReceiveFAX(\${TIFF})
 same => n,NoOp(FAXSTATUS=\${FAXSTATUS} FAXERROR=\${FAXERROR} PAGES=\${FAXPAGES})

 same => n,Set(HASFILE=\${STAT(e,\${TIFF})})
 same => n,Set(SIZE=\${STAT(s,\${TIFF})})
 same => n,GotoIf(\$[\${HASFILE} & \${SIZE} > 0]?to_pdf:no_file)

 same => n(to_pdf),System(tiff2pdf -o \${PDF} \${TIFF})
 same => n,GotoIf(\$["\${SYSTEMSTATUS}"="SUCCESS"]?cleanup:keep_tiff)

 same => n(cleanup),System(rm -f \${TIFF})
 same => n,Hangup()

 same => n(keep_tiff),NoOp(PDF failed or partial - keeping TIFF: \${TIFF})
 same => n,Hangup()

 same => n(no_file),NoOp(No TIFF created. Nothing to convert.)
 same => n,Hangup()
EOF

# ---- 8.7) AGI installieren (v1.3.6) ----
AGI=/var/lib/asterisk/agi-bin/kfx_update_status.agi
mkdir -p "$(dirname "$AGI")"
backup_file_ts "$AGI" || true

cat >"$AGI" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kfx_update_status.agi — kienzlefax
Version: 1.3.6
Stand:  2026-02-17
Autor:  Dr. Thomas Kienzle

Changelog (komplett):
- 1.3.3:
  - Retry-Policy:
    - BUSY:       15 Versuche, 90s Abstand
    - NOANSWER:    3 Versuche, 120s Abstand (kann angepasst werden)
    - alles andere retryable: 30 Versuche
      - CONGESTION/CHANUNAVAIL: 20s Abstand
      - FAXFAIL (ANSWER aber FAXSTATUS != SUCCESS): 60s Abstand
  - OK nur wenn FAXSTATUS == SUCCESS.
- 1.3.6:
  - Unterstützt Event-Style Aufrufe aus dem Dialplan:
      * ... jobid,send_start
      * ... jobid,dial_end,<DIALSTATUS>,<HANGUPCAUSE>
      * ... jobid,send_end,<FAXSTATUS>,<FAXERROR>,<FAXPAGES>,<FAXBITRATE>,<FAXECM>,<DIALSTATUS>,<HANGUPCAUSE>
    (Legacy-Signatur weiterhin kompatibel.)
  - FIX2: DIALSTATUS=CANCEL + HANGUPCAUSE=19 wird als NOANSWER behandelt (Policy: 3 Versuche),
    weil das in Praxis häufig „keiner geht ran“ bedeutet.
  - Konservative Entscheidung:
    - dial_end mit ANSWER finalisiert NICHT (wartet auf send_end oder Hangup-Handler).
    - send_end ist „Quelle der Wahrheit“ für Fax-Ergebnis.
  - Neue Reason-Klasse NOFAX:
    - Wenn ANSWER aber Fax scheitert/keine Seiten -> nur 3 Versuche (statt 30).
  - Atomare JSON-Schreibweise (tmp + replace), um kaputte job.json zu vermeiden.
"""

import json
import os
import re
import sys
from pathlib import Path
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, Optional, Tuple

BASE = Path("/srv/kienzlefax")
PROC = BASE / "processing"
QUEUE = BASE / "queue"

# Policy nach deinem Stand:
# - BUSY: 15 @ 90s
# - NOANSWER: 3 @ 90s
# - alles andere (nicht BUSY/NOANSWER): 30 @ 20s
# - NOFAX: 3 @ 20s
RETRY_RULES = {
    "BUSY":        {"delay": 90, "max": 15},
    "NOANSWER":    {"delay": 90, "max": 3},
    "CONGESTION":  {"delay": 20, "max": 30},
    "CHANUNAVAIL": {"delay": 20, "max": 30},
    "FAXFAIL":     {"delay": 20, "max": 30},
    "NOFAX":       {"delay": 20, "max": 3},
}

def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def eprint(*a: object) -> None:
    print(*a, file=sys.stderr, flush=True)

def agi_read_env() -> Dict[str, str]:
    env: Dict[str, str] = {}
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            break
        if ":" in line:
            k, v = line.split(":", 1)
            env[k.strip()] = v.strip()
    return env

def agi_send(line: str) -> None:
    sys.stdout.write(line.rstrip("\n") + "\n")
    sys.stdout.flush()

def sanitize_jobid(s: str) -> str:
    s = (s or "").strip()
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s)
    return s

def to_str(x: Any) -> str:
    return "" if x is None else str(x)

def upper(x: Any) -> str:
    return to_str(x).strip().upper()

def parse_pages(s: str) -> Tuple[Optional[int], Optional[int]]:
    s = (s or "").strip()
    if not s:
        return None, None
    m = re.match(r"^\s*(\d+)\s*[/:\s]\s*(\d+)\s*$", s)
    if m:
        return int(m.group(1)), int(m.group(2))
    if s.isdigit():
        return int(s), None
    return None, None

def find_job_json(jobid: str) -> Optional[Path]:
    direct = [
        PROC / jobid / "job.json",
        QUEUE / jobid / "job.json",
    ]
    for p in direct:
        if p.exists():
            return p
    for root in (PROC, QUEUE):
        if not root.exists():
            continue
        for d in root.iterdir():
            jp = d / "job.json"
            if not jp.exists():
                continue
            try:
                with jp.open("r", encoding="utf-8") as f:
                    j = json.load(f)
                if to_str(j.get("job_id") or d.name) == jobid:
                    return jp
            except Exception:
                continue
    return None

def read_json(p: Path) -> Dict[str, Any]:
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)

def write_json_atomic(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)

def set_attempt_meta(job: Dict[str, Any], *, ended: bool, reason: Optional[str]=None, mx: Optional[int]=None) -> None:
    a = job.setdefault("attempt", {})
    if ended:
        a["ended_at"] = now_iso()
    if reason:
        a["last_reason"] = reason
    if mx is not None:
        a["max"] = int(mx)

def apply_retry(job: Dict[str, Any], key: str) -> None:
    rule = RETRY_RULES[key]
    delay = int(rule["delay"])
    mx = int(rule["max"])

    r = job.setdefault("retry", {})
    r["max"] = mx
    r["last_reason"] = key
    r["suggested_delay_sec"] = delay
    r["next_try_at"] = (datetime.now(timezone.utc) + timedelta(seconds=delay)).replace(microsecond=0).isoformat()

    set_attempt_meta(job, ended=True, reason=key, mx=mx)

def set_result_fields(job: Dict[str, Any], **kv: str) -> None:
    res = job.setdefault("result", {})
    for k, v in kv.items():
        if v is None:
            continue
        res[k] = v if isinstance(v, str) else to_str(v)

def normalize_cancel19(dialstatus: str, hangupcause: str) -> str:
    if dialstatus == "CANCEL" and hangupcause == "19":
        return "NOANSWER"
    return dialstatus

def decide_from_send_end(dialstatus: str, hangupcause: str, faxstatus: str, faxerror: str, pages_sent: Optional[int]):
    if faxstatus == "SUCCESS":
        return "OK", "OK"

    nofax = False
    if dialstatus == "ANSWER":
        if pages_sent is not None and pages_sent <= 0:
            nofax = True
        if "dropped prematurely" in (faxerror or "").lower():
            nofax = True
        if faxerror.strip().upper() in ("HANGUP", "NO CARRIER", "NOCARRIER"):
            nofax = True

    if nofax:
        return "RETRY", "NOFAX"

    if dialstatus == "ANSWER":
        return "RETRY", "FAXFAIL"

    if dialstatus in ("BUSY", "NOANSWER", "CONGESTION", "CHANUNAVAIL"):
        return "RETRY", dialstatus

    return "FAILED", faxstatus or dialstatus or "unknown"

def decide_from_dial_end(dialstatus: str):
    if dialstatus == "ANSWER":
        return None, None
    if dialstatus in ("BUSY", "NOANSWER", "CONGESTION", "CHANUNAVAIL"):
        return "RETRY", dialstatus
    if dialstatus == "CANCEL":
        return "FAILED", "CANCEL"
    return "FAILED", dialstatus or "unknown"

def main() -> int:
    agi_env = agi_read_env()

    args = sys.argv[1:]
    if len(args) < 2:
        eprint("kfx_update_status.agi: missing args")
        return 0

    jobid = sanitize_jobid(args[0])
    if not jobid:
        eprint("kfx_update_status.agi: missing jobid")
        return 0

    jp = find_job_json(jobid)
    if not jp:
        eprint(f"kfx_update_status.agi: job.json not found for jobid={jobid}")
        return 0

    try:
        job = read_json(jp)
    except Exception as e:
        eprint(f"kfx_update_status.agi: cannot read {jp}: {e}")
        return 0

    was_cancelled = bool((job.get("cancel") or {}).get("requested"))
    action = upper(args[1])

    if action == "SEND_START":
        job["status"] = "SENDING"
        job["updated_at"] = now_iso()
        a = job.setdefault("attempt", {})
        a.setdefault("started_at", job["updated_at"])
        job.setdefault("asterisk", {})
        chan = agi_env.get("agi_channel", "")
        if chan:
            job["asterisk"]["channel_sendfax"] = chan
        uid = agi_env.get("agi_uniqueid", "")
        if uid:
            job["asterisk"]["uniqueid"] = uid
        try:
            write_json_atomic(jp, job)
        except Exception as e:
            eprint(f"kfx_update_status.agi: write failed {jp}: {e}")
        return 0

    if action == "DIAL_END":
        dialstatus = upper(args[2]) if len(args) >= 3 else ""
        hangupcause = to_str(args[3]).strip() if len(args) >= 4 else ""
        dialstatus = normalize_cancel19(dialstatus, hangupcause)
        set_result_fields(job, dialstatus=dialstatus, hangupcause=hangupcause)

        if was_cancelled:
            job["status"] = "FAILED"
            job.setdefault("result", {})["reason"] = "cancelled"
            set_attempt_meta(job, ended=True, reason="cancelled", mx=(job.get("retry") or {}).get("max"))
            job["end_time"] = now_iso()
            job["updated_at"] = job["end_time"]
            job["finalized_at"] = job.get("finalized_at") or job["end_time"]
            try:
                write_json_atomic(jp, job)
            except Exception as e:
                eprint(f"kfx_update_status.agi: write failed {jp}: {e}")
            return 0

        final_status, reason_key = decide_from_dial_end(dialstatus)
        if final_status is None:
            job["updated_at"] = now_iso()
            try:
                write_json_atomic(jp, job)
            except Exception as e:
                eprint(f"kfx_update_status.agi: write failed {jp}: {e}")
            return 0

        if final_status == "RETRY" and reason_key in RETRY_RULES:
            job["status"] = "RETRY"
            job.setdefault("result", {})["reason"] = reason_key
            apply_retry(job, reason_key)
        else:
            job["status"] = "FAILED"
            job.setdefault("result", {})["reason"] = reason_key or "FAILED"
            set_attempt_meta(job, ended=True, reason=reason_key or "FAILED", mx=(job.get("retry") or {}).get("max"))
            job["finalized_at"] = job.get("finalized_at") or now_iso()

        job["end_time"] = now_iso()
        job["updated_at"] = job["end_time"]

        try:
            write_json_atomic(jp, job)
        except Exception as e:
            eprint(f"kfx_update_status.agi: write failed {jp}: {e}")

        try:
            agi_send(f'SET VARIABLE KFX_JOB_STATUS "{job.get("status","")}"')
        except Exception:
            pass
        return 0

    if action == "SEND_END":
        faxstatus = upper(args[2]) if len(args) >= 3 else ""
        faxerror = to_str(args[3]).strip() if len(args) >= 4 else ""
        faxpages_raw = to_str(args[4]).strip() if len(args) >= 5 else ""
        faxbitrate = to_str(args[5]).strip() if len(args) >= 6 else ""
        faxecm = to_str(args[6]).strip() if len(args) >= 7 else ""
        dialstatus = upper(args[7]) if len(args) >= 8 else ""
        hangupcause = to_str(args[8]).strip() if len(args) >= 9 else ""

        dialstatus = normalize_cancel19(dialstatus, hangupcause)

        sent, total = parse_pages(faxpages_raw)
        set_result_fields(
            job,
            faxstatus=faxstatus,
            faxerror=faxerror,
            faxpages_raw=faxpages_raw,
            faxbitrate=faxbitrate,
            faxecm=faxecm,
            dialstatus=dialstatus,
            hangupcause=hangupcause,
        )
        res = job.setdefault("result", {})
        if sent is not None:
            res["faxpages_sent"] = sent
        if total is not None:
            res["faxpages_total"] = total

        if was_cancelled or dialstatus == "CANCEL":
            job["status"] = "FAILED"
            res["reason"] = "cancelled" if was_cancelled else "CANCEL"
            set_attempt_meta(job, ended=True, reason=res["reason"], mx=(job.get("retry") or {}).get("max"))
            job["finalized_at"] = job.get("finalized_at") or now_iso()
        else:
            final_status, reason_key = decide_from_send_end(dialstatus, hangupcause, faxstatus, faxerror, sent)
            if final_status == "OK":
                job["status"] = "OK"
                res["reason"] = "OK"
                set_attempt_meta(job, ended=True, reason="OK", mx=(job.get("retry") or {}).get("max"))
                job["finalized_at"] = job.get("finalized_at") or now_iso()
            elif final_status == "RETRY" and reason_key in RETRY_RULES:
                job["status"] = "RETRY"
                res["reason"] = reason_key
                apply_retry(job, reason_key)
            else:
                job["status"] = "FAILED"
                res["reason"] = reason_key or "FAILED"
                set_attempt_meta(job, ended=True, reason=res["reason"], mx=(job.get("retry") or {}).get("max"))
                job["finalized_at"] = job.get("finalized_at") or now_iso()

        job["end_time"] = now_iso()
        job["updated_at"] = job["end_time"]

        try:
            write_json_atomic(jp, job)
        except Exception as e:
            eprint(f"kfx_update_status.agi: write failed {jp}: {e}")

        try:
            agi_send(f'SET VARIABLE KFX_JOB_STATUS "{job.get("status","")}"')
        except Exception:
            pass
        return 0

    # Legacy fallback:
    legacy = args[1:]
    while len(legacy) < 8:
        legacy.append("")
    dialstatus = upper(legacy[0])
    hangupcause = to_str(legacy[1]).strip()
    faxstatus = upper(legacy[2])
    faxerror = to_str(legacy[3]).strip()
    faxpages_raw = to_str(legacy[4]).strip()
    faxbitrate = to_str(legacy[5]).strip()
    faxecm = to_str(legacy[6]).strip()

    dialstatus = normalize_cancel19(dialstatus, hangupcause)
    sent, total = parse_pages(faxpages_raw)

    set_result_fields(
        job,
        dialstatus=dialstatus,
        hangupcause=hangupcause,
        faxstatus=faxstatus,
        faxerror=faxerror,
        faxpages_raw=faxpages_raw,
        faxbitrate=faxbitrate,
        faxecm=faxecm,
    )
    res = job.setdefault("result", {})
    if sent is not None:
        res["faxpages_sent"] = sent
    if total is not None:
        res["faxpages_total"] = total

    if was_cancelled:
        job["status"] = "FAILED"
        res["reason"] = "cancelled"
        set_attempt_meta(job, ended=True, reason="cancelled", mx=(job.get("retry") or {}).get("max"))
        job["finalized_at"] = job.get("finalized_at") or now_iso()
    else:
        if faxstatus == "SUCCESS":
            job["status"] = "OK"
            res["reason"] = "OK"
            set_attempt_meta(job, ended=True, reason="OK", mx=(job.get("retry") or {}).get("max"))
            job["finalized_at"] = job.get("finalized_at") or now_iso()
        else:
            final_status, reason_key = decide_from_send_end(dialstatus, hangupcause, faxstatus, faxerror, sent)
            if final_status == "RETRY" and reason_key in RETRY_RULES:
                job["status"] = "RETRY"
                res["reason"] = reason_key
                apply_retry(job, reason_key)
            else:
                job["status"] = "FAILED"
                res["reason"] = reason_key or "FAILED"
                set_attempt_meta(job, ended=True, reason=res["reason"], mx=(job.get("retry") or {}).get("max"))
                job["finalized_at"] = job.get("finalized_at") or now_iso()

    job["end_time"] = now_iso()
    job["updated_at"] = job["end_time"]
    try:
        write_json_atomic(jp, job)
    except Exception as e:
        eprint(f"kfx_update_status.agi: write failed {jp}: {e}")

    try:
        agi_send(f'SET VARIABLE KFX_JOB_STATUS "{job.get("status","")}"')
    except Exception:
        pass
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        eprint(f"kfx_update_status.agi: fatal: {e}")
        sys.exit(0)
PY

chmod 0755 "$AGI"
if id asterisk >/dev/null 2>&1; then
  chown asterisk:asterisk "$AGI"
else
  chown root:root "$AGI" || true
fi
python3 -m py_compile "$AGI"

# ---- 8.8) Worker installieren (v1.3.5) + systemd ----
W="/usr/local/bin/kienzlefax-worker.py"
backup_file_ts "$W" || true

cat >"$W" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kienzlefax-worker.py — Asterisk-Only Worker (SendFAX)
Version: 1.3.5
Stand:  2026-02-17
Autor:  Dr. Thomas Kienzle

Changelog (komplett):
- 1.2.4:
  - Live-Status-Felder (faxstat -sal) in job.json (HylaFAX).
  - Reboot-sicherer Lock via flock.
- 1.3.0:
  - Beginn Umstieg von HylaFAX-sendfax auf Asterisk AMI Originate + Dialplan SendFAX().
- 1.3.1:
  - AMI-basierter Versand stabilisiert; Rechte/Manager-User Themen sichtbar gemacht.
- 1.3.2:
  - HylaFAX-Legacy entfernt: Finalisierung basiert ausschließlich auf AGI-Ergebnis in job.json.
  - Retry-Handling: status=RETRY => zurück in Queue (Backoff via retry.next_try_at, attempt, etc.).
  - Cooldown nach jedem Call-Ende (terminal oder RETRY) für Gerätepause.
  - Asterisk-Originate so implementiert, dass fax-out NICHT doppelt ausgeführt wird:
    Local/<exten>@<context>/n + Application=Wait (kein Context/Exten/Priority im AMI-Action).
  - PDF->TIFF/F Konvertierung (tiffg4) für SendFAX.
  - Report+Dokument werden weiterhin als PDF zusammengeführt (qpdf), für Archiv/Fehler.
- 1.3.3:
  - Retry-Limits werden erzwungen (basierend auf retry.* Feldern).
  - Report enthält Retry-Infos.
- 1.3.4:
  - Versuchszähler umgebaut (attempt.current als kanonisch).
- 1.3.5:
  - FIX: attempt.current wird jetzt beim START eines Attempts hochgezählt (submit_job),
    nicht beim Requeue. Dadurch zählt jeder tatsächliche Originate/Call genau 1 Versuch,
    unabhängig davon, ob/wo der Job requeued wird.
  - Limit-Prüfung: wenn attempt.current > attempt.max (oder retry.max) -> final FAILED.
  - POST_CALL_COOLDOWN default 20s (per ENV übersteuerbar).
"""

import fcntl
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Tuple, List

BASE = Path(os.environ.get("KFX_BASE", "/srv/kienzlefax"))
QUEUE = BASE / "queue"
PROC = BASE / "processing"
ARCH_OK = BASE / "sendeberichte"
FAIL_IN = BASE / "sendefehler" / "eingang"
FAIL_OUT = BASE / "sendefehler" / "berichte"

AMI_HOST = os.environ.get("KFX_AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("KFX_AMI_PORT", "5038"))
AMI_USER = os.environ.get("KFX_AMI_USER", "kfx")
AMI_PASS = os.environ.get("KFX_AMI_PASS", "")
DIAL_CONTEXT = os.environ.get("KFX_DIAL_CONTEXT", "fax-out")

QPDF_BIN = os.environ.get("KFX_QPDF_BIN", "qpdf")
GS_BIN = os.environ.get("KFX_GS_BIN", "gs")
PDF_HEADER_SCRIPT = Path(os.environ.get("KFX_PDF_HEADER_SCRIPT", "/usr/local/bin/pdf_with_header.sh"))

MAX_INFLIGHT_PROCESSING = int(os.environ.get("KFX_MAX_INFLIGHT", "1"))
POLL_INTERVAL_SEC = float(os.environ.get("KFX_POLL_INTERVAL_SEC", "1.0"))
POST_CALL_COOLDOWN_SEC = float(os.environ.get("KFX_POST_CALL_COOLDOWN_SEC", "20.0"))

TIFF_DPI = os.environ.get("KFX_TIFF_DPI", "204x196")
TIFF_DEVICE = os.environ.get("KFX_TIFF_DEVICE", "tiffg4")

LOCKFILE = BASE / ".kienzlefax-worker.lock"
LOG_PREFIX = "kienzlefax-worker"
_lock_fd: Optional[int] = None
_next_submit_ts: float = 0.0

def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def log(msg: str) -> None:
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"[{ts}] {LOG_PREFIX}: {msg}", flush=True)

def safe_mkdir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)

def read_json(p: Path) -> Dict[str, Any]:
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)

def write_json(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, p)

def sanitize_basename(name: str) -> str:
    name = (name or "").strip()
    name = re.sub(r"\s+", "_", name)
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
    name = name.strip("._-")
    return name or "fax"

def normalize_number(num: str) -> str:
    num = (num or "").strip()
    num = re.sub(r"\D+", "", num)
    return num

def list_jobdirs(root: Path) -> List[Path]:
    if not root.exists():
        return []
    dirs = [p for p in root.iterdir() if p.is_dir()]
    dirs.sort(key=lambda x: x.name)
    return dirs

def run_cmd(cmd: List[str], *, env: Optional[dict]=None, timeout: Optional[int]=None) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or ""), (p.stderr or "")

def add_header_pdf(pdf: Path) -> Path:
    if not PDF_HEADER_SCRIPT.exists():
        return pdf
    out = pdf.with_name(pdf.stem + "_hdr.pdf")
    try:
        subprocess.run([str(PDF_HEADER_SCRIPT), str(pdf), str(out)],
                       check=True, capture_output=True, text=True, timeout=60)
        if out.exists() and out.stat().st_size > 0:
            return out
    except Exception as e:
        log(f"header script failed -> continue without header: {e}")
    return pdf

def pdf_to_tiff_g4(pdf: Path, tif: Path) -> None:
    cmd = [
        GS_BIN,
        "-q","-dNOPAUSE","-dBATCH","-dSAFER",
        f"-sDEVICE={TIFF_DEVICE}",
        f"-r{TIFF_DPI}",
        "-sPAPERSIZE=a4","-dFIXEDMEDIA","-dPDFFitPage",
        f"-sOutputFile={str(tif)}",
        str(pdf),
    ]
    rc, so, se = run_cmd(cmd)
    if rc != 0 or (not tif.exists()) or tif.stat().st_size == 0:
        raise RuntimeError(f"ghostscript pdf->tiff failed rc={rc} out={so.strip()} err={se.strip()}")

def merge_report_and_doc(report_pdf: Path, doc_pdf: Path, out_pdf: Path) -> None:
    cmd = [QPDF_BIN, "--empty", "--pages", str(report_pdf), str(doc_pdf), "--", str(out_pdf)]
    rc, so, se = run_cmd(cmd)
    if rc != 0:
        raise RuntimeError(f"qpdf merge failed rc={rc} out={so.strip()} err={se.strip()}")

def ensure_dirs() -> None:
    for p in (QUEUE, PROC, ARCH_OK, FAIL_IN, FAIL_OUT):
        safe_mkdir(p)

def acquire_lock() -> None:
    global _lock_fd
    safe_mkdir(BASE)
    fd = os.open(str(LOCKFILE), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise SystemExit(f"{LOG_PREFIX}: already running (lock held: {LOCKFILE})")
    try:
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode("ascii", errors="ignore"))
        os.fsync(fd)
    except Exception:
        pass
    _lock_fd = fd

def release_lock() -> None:
    global _lock_fd
    if _lock_fd is None:
        return
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        os.close(_lock_fd)
    except Exception:
        pass
    _lock_fd = None

def retry_due(job: Dict[str, Any]) -> bool:
    rt = (job.get("retry") or {}).get("next_try_at")
    if not rt:
        return True
    try:
        dt = datetime.fromisoformat(str(rt).replace("Z", "+00:00")).astimezone(timezone.utc)
        return datetime.now(timezone.utc) >= dt
    except Exception:
        return True

def _st_norm(job: Dict[str, Any]) -> str:
    return str(job.get("status") or "").strip().upper()

def count_inflight() -> int:
    n = 0
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        st = _st_norm(job)
        if st in ("CLAIMED", "SUBMITTED", "PROCESSING", "CALLING", "SENDING"):
            n += 1
    return n

def get_busy_numbers() -> set[str]:
    busy: set[str] = set()
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        st = _st_norm(job)
        if st in ("CLAIMED", "SUBMITTED", "PROCESSING", "CALLING", "SENDING", "RETRY_WAIT"):
            num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
            if num:
                busy.add(num)
    return busy

def claim_next_job_skipping_busy(busy_numbers: set[str]) -> Optional[Path]:
    for j in list_jobdirs(QUEUE):
        jp = j / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        if not retry_due(job):
            continue
        num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
        if num and num in busy_numbers:
            continue
        target = PROC / j.name
        try:
            j.rename(target)
            log(f"claimed {j.name} (num={num or 'n/a'})")
            return target
        except Exception as e:
            log(f"claim rename failed for {j.name}: {e}")
            continue
    return None

def find_original_pdf_in_jobdir(jobdir: Path) -> Optional[Path]:
    for c in (jobdir / "doc.pdf", jobdir / "source.pdf"):
        try:
            if c.exists() and c.stat().st_size > 0:
                return c
        except Exception:
            pass
    return None

def copy_original_to_fail_in(jobdir: Path, job: Dict[str, Any]) -> None:
    safe_mkdir(FAIL_IN)
    src = job.get("source") or {}
    jobid = job.get("job_id") or jobdir.name
    orig_path = find_original_pdf_in_jobdir(jobdir)
    if not orig_path:
        return
    base = sanitize_basename(Path(src.get("filename_original") or "document").stem) or "document"
    dest = FAIL_IN / f"{base}.pdf"
    if dest.exists():
        dest = FAIL_IN / f"{base}__{jobid}.pdf"
    shutil.copy2(str(orig_path), str(dest))
    log(f"fail: original copied -> {dest.name}")

def build_report_pdf(job: Dict[str, Any], out_pdf: Path) -> None:
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas
    c = canvas.Canvas(str(out_pdf), pagesize=A4)
    _, h = A4

    status = str(job.get("status") or "").upper()
    res = job.get("result") or {}
    reason = str(res.get("reason") or "")
    dial = str(res.get("dialstatus") or "")
    hcause = str(res.get("hangupcause") or "")
    faxst = str(res.get("faxstatus") or "")
    faxerr = str(res.get("faxerror") or "")
    pages_raw = str(res.get("faxpages_raw") or "")

    retry = job.get("retry") or {}
    r_max = retry.get("max")
    r_next = retry.get("next_try_at")
    r_last = retry.get("last_reason")

    a = job.get("attempt") or {}
    a_cur = a.get("current")
    a_max = a.get("max")
    a_last = a.get("last_reason")

    job_id = job.get("job_id") or ""
    rec = job.get("recipient") or {}
    src = job.get("source") or {}

    y = h - 60
    c.setFont("Helvetica-Bold", 20)
    c.drawString(50, y, "Fax-Sendebericht")
    y -= 35

    c.setFont("Helvetica-Bold", 16)
    c.drawString(50, y, f"Status: {status}")
    y -= 24

    c.setFont("Helvetica", 11)
    c.drawString(50, y, f"Job-ID: {job_id}")
    y -= 16
    c.drawString(50, y, f"Empfänger: {rec.get('name','')}  |  Nummer: {rec.get('number','')}")
    y -= 16
    c.drawString(50, y, f"Quelle: {src.get('src','')}  |  Datei: {src.get('filename_original','')}")
    y -= 20

    c.drawString(50, y, f"Dialstatus: {dial}  |  Hangupcause: {hcause}")
    y -= 16
    c.drawString(50, y, f"Faxstatus: {faxst}  |  Faxerror: {faxerr}")
    y -= 16
    if pages_raw:
        c.drawString(50, y, f"Seiten: {pages_raw}")
        y -= 16
    if reason:
        c.drawString(50, y, f"Grund: {reason}")
        y -= 16

    if a_cur is not None or a_max is not None or a_last:
        c.drawString(50, y, f"Attempt: current={a_cur} max={a_max} last_reason={a_last or ''}")
        y -= 16

    if r_max is not None or r_next or r_last:
        c.drawString(50, y, f"Retry: max={r_max} last_reason={r_last or ''}")
        y -= 16
        if r_next:
            c.drawString(50, y, f"Next try at (UTC): {r_next}")
            y -= 16

    c.setFont("Helvetica", 9)
    c.drawString(50, 40, f"Erzeugt: {now_iso()}  |  kienzlefax-worker v1.3.5")
    c.showPage()
    c.save()

class AmiError(Exception):
    pass

def ami_send(sockf, line: str) -> None:
    sockf.write((line.rstrip("\r\n") + "\r\n").encode("utf-8", errors="ignore"))

def ami_read_response(sockf) -> str:
    buf = bytearray()
    while True:
        line = sockf.readline()
        if not line:
            break
        buf += line
        if line in (b"\r\n", b"\n"):
            break
    return buf.decode("utf-8", errors="replace")

def ami_login(sockf) -> None:
    ami_send(sockf, "Action: Login")
    ami_send(sockf, f"Username: {AMI_USER}")
    ami_send(sockf, f"Secret: {AMI_PASS}")
    ami_send(sockf, "Events: off")
    ami_send(sockf, "")
    r = ami_read_response(sockf)
    if "Response: Success" not in r:
        raise AmiError(f"AMI login failed: {r.strip()}")

def ami_logoff(sockf) -> None:
    try:
        ami_send(sockf, "Action: Logoff")
        ami_send(sockf, "")
        _ = ami_read_response(sockf)
    except Exception:
        pass

def ami_originate_local(jobid: str, exten: str, tiff_path: str) -> None:
    if not AMI_PASS:
        raise AmiError("AMI password missing (KFX_AMI_PASS)")

    action_id = f"kfx-{jobid}"
    channel = f"Local/{exten}@{DIAL_CONTEXT}/n"

    s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
    sockf = s.makefile("rwb", buffering=0)
    try:
        _ = sockf.readline()
        ami_login(sockf)

        ami_send(sockf, "Action: Originate")
        ami_send(sockf, f"ActionID: {action_id}")
        ami_send(sockf, f"Channel: {channel}")
        ami_send(sockf, "Async: true")

        ami_send(sockf, "Application: Wait")
        ami_send(sockf, "Data: 3600")

        ami_send(sockf, f"Variable: KFX_JOBID={jobid}")
        ami_send(sockf, f"Variable: KFX_FILE={tiff_path}")
        ami_send(sockf, "")

        r = ami_read_response(sockf)
        if "Response: Success" not in r:
            raise AmiError(f"AMI originate failed: {r.strip()}")
    finally:
        try:
            ami_logoff(sockf)
        finally:
            try: sockf.close()
            except Exception: pass
            try: s.close()
            except Exception: pass

def prepare_send_files(jobdir: Path, job: Dict[str, Any]) -> Tuple[Path, Path]:
    pdf_in = find_original_pdf_in_jobdir(jobdir)
    if not pdf_in:
        raise RuntimeError("missing doc.pdf/source.pdf")
    pdf_for_archive = add_header_pdf(pdf_in)
    tiff = jobdir / "doc.tif"
    if (not tiff.exists()) or (tiff.stat().st_size == 0):
        pdf_to_tiff_g4(pdf_for_archive, tiff)
    return pdf_for_archive, tiff

def _attempt_limit_reached(job: Dict[str, Any]) -> bool:
    a = job.get("attempt") or {}
    r = job.get("retry") or {}
    try:
        cur = int(a.get("current") or 0)
    except Exception:
        cur = 0
    mx = a.get("max", r.get("max"))
    try:
        mx_int = int(mx) if mx is not None else 0
    except Exception:
        mx_int = 0
    return (mx_int > 0 and cur > mx_int)

def submit_job(jobdir: Path) -> None:
    global _next_submit_ts
    jp = jobdir / "job.json"
    if not jp.exists():
        log(f"submit: missing job.json in {jobdir}")
        return

    job = read_json(jp)

    if bool((job.get("cancel") or {}).get("requested")):
        job["status"] = "FAILED"
        job.setdefault("result", {})["reason"] = "cancelled"
        job["end_time"] = now_iso()
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]
        write_json(jp, job)
        return

    if _attempt_limit_reached(job):
        job["status"] = "FAILED"
        job.setdefault("result", {})["reason"] = "max attempts reached"
        job["finalized_at"] = job.get("finalized_at") or now_iso()
        job["end_time"] = job.get("end_time") or job["finalized_at"]
        write_json(jp, job)
        return

    rec = job.get("recipient") or {}
    number = normalize_number(rec.get("number") or "")
    if not number:
        raise RuntimeError("invalid recipient number")

    pdf_for_archive, tiff = prepare_send_files(jobdir, job)

    job["claimed_at"] = job.get("claimed_at") or now_iso()
    job["submitted_at"] = now_iso()
    job["started_at"] = job.get("started_at") or job["submitted_at"]

    a = job.setdefault("attempt", {})
    try:
        prev = int(a.get("current") or 0)
    except Exception:
        prev = 0
    a["current"] = prev + 1
    a["started_at"] = job["submitted_at"]

    r = job.get("retry") or {}
    if r.get("max") is not None:
        try:
            a["max"] = int(r.get("max"))
        except Exception:
            pass
    if r.get("last_reason"):
        a["last_reason"] = str(r.get("last_reason"))

    job["status"] = "CALLING"
    job["updated_at"] = job["submitted_at"]

    job.setdefault("asterisk", {})
    job["asterisk"]["dial_context"] = DIAL_CONTEXT
    job["asterisk"]["exten"] = number
    job["asterisk"]["tiff"] = str(tiff)
    job["asterisk"]["pdf_for_archive"] = str(pdf_for_archive)
    job["asterisk"]["accountcode"] = str(job.get("job_id") or jobdir.name)
    job["asterisk"]["cdr_userfield"] = f"kfx:{job.get('job_id') or jobdir.name}"

    write_json(jp, job)

    try:
        ami_originate_local(jobid=str(job.get("job_id") or jobdir.name),
                            exten=number,
                            tiff_path=str(tiff))
        log(f"submitted via AMI -> {jobdir.name} exten={number} attempt={a.get('current')}")
    except Exception as e:
        job = read_json(jp)
        job["status"] = "FAILED"
        job.setdefault("result", {})["reason"] = f"ami_originate_failed: {e}"
        job["end_time"] = now_iso()
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]
        write_json(jp, job)
        log(f"submit failed for {jobdir.name}: {e}")
        _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC

def finalize_ok(jobdir: Path, job: Dict[str, Any]) -> None:
    safe_mkdir(ARCH_OK)
    src = job.get("source") or {}
    base = sanitize_basename(Path(src.get("filename_original") or "fax").stem)
    jobid = job.get("job_id") or jobdir.name

    report_pdf = jobdir / "report.pdf"
    merged_pdf = jobdir / "merged.pdf"

    pdf_for_archive = Path((job.get("asterisk") or {}).get("pdf_for_archive") or "")
    if not pdf_for_archive.exists():
        pdf_for_archive = find_original_pdf_in_jobdir(jobdir) or (jobdir / "doc.pdf")

    build_report_pdf(job, report_pdf)
    merge_report_and_doc(report_pdf, pdf_for_archive, merged_pdf)

    out_pdf = ARCH_OK / f"{base}__{jobid}__OK.pdf"
    out_json = ARCH_OK / f"{base}__{jobid}.json"
    shutil.move(str(merged_pdf), str(out_pdf))
    write_json(out_json, job)
    log(f"finalize OK -> {out_pdf.name}")

def finalize_failed(jobdir: Path, job: Dict[str, Any]) -> None:
    safe_mkdir(FAIL_OUT)
    try:
        copy_original_to_fail_in(jobdir, job)
    except Exception as e:
        log(f"fail: copy original failed: {e}")

    src = job.get("source") or {}
    base = sanitize_basename(Path(src.get("filename_original") or "fax").stem)
    jobid = job.get("job_id") or jobdir.name

    report_pdf = jobdir / "report.pdf"
    merged_pdf = jobdir / "merged.pdf"

    pdf_for_archive = Path((job.get("asterisk") or {}).get("pdf_for_archive") or "")
    if not pdf_for_archive.exists():
        pdf_for_archive = find_original_pdf_in_jobdir(jobdir) or (jobdir / "doc.pdf")

    build_report_pdf(job, report_pdf)
    merge_report_and_doc(report_pdf, pdf_for_archive, merged_pdf)

    out_pdf = FAIL_OUT / f"{base}__{jobid}__FAILED.pdf"
    out_json = FAIL_OUT / f"{base}__{jobid}.json"
    shutil.move(str(merged_pdf), str(out_pdf))
    write_json(out_json, job)
    log(f"finalize FAILED -> {out_pdf.name}")

def requeue_retry(jobdir: Path, job: Dict[str, Any]) -> None:
    job["status"] = "RETRY_WAIT"
    job["updated_at"] = now_iso()
    write_json(jobdir / "job.json", job)

    target = QUEUE / jobdir.name
    try:
        jobdir.rename(target)
        r = job.get("retry") or {}
        a = job.get("attempt") or {}
        log(
            f"retry scheduled attempt={a.get('current','?')}/{a.get('max', r.get('max','?'))} "
            f"reason={r.get('last_reason','')} next_try_at={r.get('next_try_at','')} -> {target.name}"
        )
    except Exception as e:
        log(f"retry move back to queue failed for {jobdir.name}: {e}")

def step_finalize_processing() -> None:
    global _next_submit_ts
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue

        st = _st_norm(job)

        if st == "OK":
            try:
                if not job.get("finalized_at"):
                    job["finalized_at"] = now_iso()
                job["end_time"] = job.get("end_time") or job["finalized_at"]
                write_json(jp, job)
                finalize_ok(jdir, job)
            except Exception as e:
                log(f"finalize OK exception {jdir.name}: {e}")
            shutil.rmtree(jdir, ignore_errors=True)
            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

        if st == "FAILED":
            try:
                if not job.get("finalized_at"):
                    job["finalized_at"] = now_iso()
                job["end_time"] = job.get("end_time") or job["finalized_at"]
                write_json(jp, job)
                finalize_failed(jdir, job)
            except Exception as e:
                log(f"finalize FAILED exception {jdir.name}: {e}")
            shutil.rmtree(jdir, ignore_errors=True)
            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

        if st in ("RETRY", "RETRY_WAIT"):
            try:
                if _attempt_limit_reached(job):
                    job["status"] = "FAILED"
                    job.setdefault("result", {})
                    base_reason = str((job.get("result") or {}).get("reason") or "RETRY")
                    mx = (job.get("attempt") or {}).get("max", (job.get("retry") or {}).get("max"))
                    job["result"]["reason"] = f"{base_reason} (max attempts reached: {mx})"
                    job["finalized_at"] = job.get("finalized_at") or now_iso()
                    job["end_time"] = job.get("end_time") or job["finalized_at"]
                    write_json(jp, job)
                    finalize_failed(jdir, job)
                    shutil.rmtree(jdir, ignore_errors=True)
                    _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
                    continue

                requeue_retry(jdir, job)
            except Exception as e:
                log(f"requeue exception {jdir.name}: {e}")

            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

def step_submit() -> None:
    global _next_submit_ts
    if time.time() < _next_submit_ts:
        return

    inflight = count_inflight()
    if inflight >= MAX_INFLIGHT_PROCESSING:
        return

    busy = get_busy_numbers()
    while inflight < MAX_INFLIGHT_PROCESSING:
        jdir = claim_next_job_skipping_busy(busy)
        if not jdir:
            return

        jp = jdir / "job.json"
        try:
            job = read_json(jp)
            job["claimed_at"] = job.get("claimed_at") or now_iso()
            if not job.get("status"):
                job["status"] = "PROCESSING"
            job["updated_at"] = now_iso()
            write_json(jp, job)

            num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
            if num:
                busy.add(num)
        except Exception:
            pass

        try:
            submit_job(jdir)
        except Exception as e:
            log(f"submit exception {jdir.name}: {e}")
            try:
                job = read_json(jp)
                job["status"] = "FAILED"
                job.setdefault("result", {})["reason"] = f"submit_exception: {e}"
                job["end_time"] = now_iso()
                job["finalized_at"] = job.get("finalized_at") or job["end_time"]
                write_json(jp, job)
            except Exception:
                pass

        inflight = count_inflight()

def main() -> None:
    ensure_dirs()
    acquire_lock()
    log("started (v1.3.5)")
    try:
        while True:
            step_finalize_processing()
            step_submit()
            time.sleep(POLL_INTERVAL_SEC)
    finally:
        release_lock()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("stopped by user")
        sys.exit(0)
PY

chown root:root "$W"
chmod 0755 "$W"
python3 -m py_compile "$W"

cat >/etc/default/kienzlefax-worker <<EOF
# kienzlefax-worker env
KFX_BASE=/srv/kienzlefax

KFX_AMI_HOST=127.0.0.1
KFX_AMI_PORT=5038
KFX_AMI_USER=kfx
KFX_AMI_PASS=${AMI_SECRET}

KFX_DIAL_CONTEXT=fax-out

# optional tuning
KFX_MAX_INFLIGHT=1
KFX_POST_CALL_COOLDOWN_SEC=20
EOF
chmod 0644 /etc/default/kienzlefax-worker

cat >/etc/systemd/system/kienzlefax-worker.service <<'EOF'
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
EOF

# ---- 8.9) Reload/Restart Asterisk + sanity checks ----
systemctl daemon-reload

# asterisk (falls unit existiert)
svc_enable_now asterisk.service

# reload dialplan + manager
asterisk -rx "dialplan reload" || true
asterisk -rx "manager reload" || true
asterisk -rx "manager show user kfx" || true

# worker starten
systemctl enable --now kienzlefax-worker.service
systemctl status kienzlefax-worker.service --no-pager -l || true

# ------------------------------------------------------------------------------
# 9) GANZ AM ENDE: /usr/local/bin/pdf_with_header.sh
# ------------------------------------------------------------------------------
sep "GANZ AM ENDE: /usr/local/bin/pdf_with_header.sh erstellen"

tee /usr/local/bin/pdf_with_header.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   pdf_with_header.sh INPUT.pdf OUTPUT.pdf
#
# Header on EACH page:
#   Left:  "<DATE>"
#   Center:"<PRACTICE_NAME>"
#   Right: "Seite X/Y"
#
# Customize via env:
#   PRACTICE_NAME="Praxis Dr. Thomas Mustermann"
#   DATE_FMT="%d.%m.%Y %H:%M"
#   TOP_OFFSET_MM="6"     # distance from top edge to text baseline (smaller => higher)
#   FONT_NAME="Helvetica"
#   FONT_SIZE="9"
#   LEFT_MARGIN_MM="12"
#   RIGHT_MARGIN_MM="12"

IN="${1:-}"
OUT="${2:-}"
[[ -n "$IN" && -n "$OUT" ]] || { echo "Usage: pdf_with_header.sh INPUT.pdf OUTPUT.pdf" >&2; exit 2; }
[[ -f "$IN" ]] || { echo "Input not found: $IN" >&2; exit 2; }

PRACTICE_NAME="${PRACTICE_NAME:-Praxis}"
DATE_FMT="${DATE_FMT:-%d.%m.%Y %H:%M}"
TOP_OFFSET_MM="${TOP_OFFSET_MM:-6}"
FONT_NAME="${FONT_NAME:-Helvetica}"
FONT_SIZE="${FONT_SIZE:-9}"
LEFT_MARGIN_MM="${LEFT_MARGIN_MM:-12}"
RIGHT_MARGIN_MM="${RIGHT_MARGIN_MM:-12}"

export PRACTICE_NAME DATE_FMT TOP_OFFSET_MM FONT_NAME FONT_SIZE LEFT_MARGIN_MM RIGHT_MARGIN_MM
export INFILE="$IN" OUTFILE="$OUT"

python3 - <<'PY'
import os, io, datetime
from reportlab.pdfgen import canvas
from reportlab.lib.units import mm

try:
    from pypdf import PdfReader, PdfWriter
except Exception:
    from PyPDF2 import PdfReader, PdfWriter  # type: ignore

IN = os.environ.get("INFILE")
OUT = os.environ.get("OUTFILE")
if not IN or not OUT:
    raise SystemExit("INFILE/OUTFILE not set")

PRACTICE_NAME = os.environ.get("PRACTICE_NAME", "Praxis")
DATE_FMT = os.environ.get("DATE_FMT", "%d.%m.%Y %H:%M")
TOP_OFFSET_MM = float(os.environ.get("TOP_OFFSET_MM", "6"))
FONT_NAME = os.environ.get("FONT_NAME", "Helvetica")
FONT_SIZE = float(os.environ.get("FONT_SIZE", "9"))
LEFT_MARGIN_MM = float(os.environ.get("LEFT_MARGIN_MM", "12"))
RIGHT_MARGIN_MM = float(os.environ.get("RIGHT_MARGIN_MM", "12"))

reader = PdfReader(IN)
writer = PdfWriter()

total = len(reader.pages)
date_str = datetime.datetime.now().strftime(DATE_FMT)

for i, page in enumerate(reader.pages, start=1):
    media = page.mediabox
    w = float(media.width)
    h = float(media.height)

    packet = io.BytesIO()
    c = canvas.Canvas(packet, pagesize=(w, h))
    c.setFont(FONT_NAME, FONT_SIZE)

    y = h - (TOP_OFFSET_MM * mm)
    left_x = LEFT_MARGIN_MM * mm
    right_x = w - (RIGHT_MARGIN_MM * mm)

    c.drawString(left_x, y, date_str)
    c.drawCentredString(w / 2.0, y, PRACTICE_NAME)
    c.drawRightString(right_x, y, f"Seite {i}/{total}")

    c.showPage()
    c.save()

    packet.seek(0)
    overlay_reader = PdfReader(packet)
    overlay_page = overlay_reader.pages[0]

    try:
        page.merge_page(overlay_page)
    except Exception:
        page.mergePage(overlay_page)  # legacy

    writer.add_page(page)

with open(OUT, "wb") as f:
    writer.write(f)
PY
EOF

chmod +x /usr/local/bin/pdf_with_header.sh

# ------------------------------------------------------------------------------
# 10) Finale Checks (nicht blockierend)
# ------------------------------------------------------------------------------
sep "Finale Checks"

systemctl status apache2 --no-pager || true
systemctl status cups --no-pager || true
systemctl status smbd --no-pager || true
systemctl status asterisk --no-pager || true
systemctl status kienzlefax-worker --no-pager || true

echo
echo "======================================================================"
echo "INSTALLER DONE (kienzlefax-installer.sh v2.1)."
echo "Web:  http://<host>/kienzlefax.php"
echo "AMI:  127.0.0.1:5038 user=kfx (lokal only)"
echo "======================================================================"

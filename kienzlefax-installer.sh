#!/usr/bin/env bash
# ==============================================================================
# kienzlefax-installer.sh  (Raspberry Pi OS 13 / Debian 13)
#
# EIN-Datei-Installer (root-only, keine sudo-Aufrufe im Script).
#
# Was dieses Script tut:
#  1) Fragt am ANFANG die notwendigen Provider-Parameter ab:
#     - DynDNS/Public FQDN
#     - SIP Nummer (gleich Username)
#     - SIP Passwort (2× verdeckt)
#     - optional: FAX DID (Default = SIP Nummer)
#  2) apt-get update + apt-get -y upgrade
#  3) Installiert Pakete gebündelt am Anfang (OHNE HylaFAX, OHNE iaxmodem)
#  4) Installiert Web (kienzlefax.php + faxton.mp3)
#  5) Legt User admin (Login + sudo) an und fragt Passwörter ab (Linux 2×, Samba 2×)
#  6) Installiert CUPS Backend + fax1..fax5 + Bonjour/DNS-SD + Samba Shares
#  7) Baut SpanDSP + Asterisk (INTERAKTIV: make menuselect)
#  8) Ganz am ENDE: schreibt Asterisk-Configs (integriert)
#  9) Ganz am ENDE: erstellt /usr/local/bin/pdf_with_header.sh (Header je Seite)
#
# INTERAKTIV:
#  - SIP Passwort (2×)
#  - Linux admin Passwort (2×)
#  - Samba admin Passwort (2×)
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
  [[ ${EUID:-0} -eq 0 ]] || die "Bitte als root ausführen (sudo)."
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

# ------------------------------------------------------------------------------
# Preconditions + Parameterabfrage (GANZ AM ANFANG)
# ------------------------------------------------------------------------------
require_root
export DEBIAN_FRONTEND=noninteractive

sep "Provider-Parameter abfragen (DynDNS/FQDN, SIP Nummer, SIP Passwort)"

read -r -p "DynDNS / Public FQDN (z.B. myhost.dyndns.org): " PUBLIC_FQDN
[[ -n "${PUBLIC_FQDN}" ]] || die "PUBLIC_FQDN darf nicht leer sein."

read -r -p "SIP Nummer (gleich Username, nur Ziffern, z.B. 4923...): " SIP_NUMBER_RAW
SIP_NUMBER="$(sanitize_digits "${SIP_NUMBER_RAW}")"
[[ -n "${SIP_NUMBER}" ]] || die "SIP Nummer ist leer/ungültig."

read_secret_twice "SIP Passwort" SIP_PASSWORD

read -r -p "FAX DID (Enter = ${SIP_NUMBER}): " FAX_DID_IN
FAX_DID="$(sanitize_digits "${FAX_DID_IN:-$SIP_NUMBER}")"
[[ -n "${FAX_DID}" ]] || die "FAX_DID darf nicht leer sein."
unset SIP_NUMBER_RAW FAX_DID_IN

log "[OK] Parameter gesetzt:"
log " - PUBLIC_FQDN=${PUBLIC_FQDN}"
log " - SIP_NUMBER=${SIP_NUMBER}"
log " - FAX_DID=${FAX_DID}"

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

# ------------------------------------------------------------------------------
# 1) apt update/upgrade + Pakete gebündelt
# ------------------------------------------------------------------------------
sep "System aktualisieren + Pakete installieren (gebündelt, OHNE HylaFAX, OHNE iaxmodem)"

apt-get update
apt-get -y upgrade

# Hinweis: tiff2pdf wird in extensions.conf genutzt -> libtiff-tools nötig.
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
# 3) Admin-Account (Login + sudo + Samba) – interaktiv (2× + 2×)
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
sep "CUPS Backend + fax1..fax5 + Bonjour + Samba Shares"

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
# idempotent: ersetze oder ergänze
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
echo "======================================================================"
echo
make menuselect

make -j"$(nproc)"
make install
make samples
make config
ldconfig

# ------------------------------------------------------------------------------
# 8) Ganz am Ende: Asterisk-Config Bootstrap (integriert)
# ------------------------------------------------------------------------------
kienzlefax_bootstrap_asterisk_configs(){
  local STAMP_SUFFIX="old.kienzlefax"

  local PUBLIC_FQDN_LOCAL="${PUBLIC_FQDN}"
  local SIP_BIND_IP="0.0.0.0"
  local SIP_BIND_PORT="5070"
  local LOCAL_NETS=("10.0.0.0/8" "192.168.0.0/16")

  local RTP_START="12000"
  local RTP_END="12049"

  local SIP_SERVER_URI="sip:sip.1und1.de"
  local SIP_CLIENT_URI="sip:${SIP_NUMBER}@sip.1und1.de"
  local SIP_CONTACT_USER="${SIP_NUMBER}"
  local SIP_USERNAME="${SIP_NUMBER}"
  local SIP_PASSWORD_LOCAL="${SIP_PASSWORD}"

  local FROM_USER="${SIP_NUMBER}"
  local FROM_DOMAIN="sip.1und1.de"

  local FAX_DID_LOCAL="${FAX_DID}"
  local PROVIDER_MATCH_NET="212.227.0.0/16"

  local FAX_ECM="yes"
  local FAX_MAXRATE="9600"

  local SPOOL_TIFF_DIR="/var/spool/asterisk/fax1"
  local SPOOL_PDF_DIR="/var/spool/asterisk/fax"

  say(){ echo -e "\n### $*"; }
  backup_file(){
    local f="$1"
    if [ -e "$f" ] && [ ! -e "${f}.${STAMP_SUFFIX}" ]; then
      cp -a "$f" "${f}.${STAMP_SUFFIX}"
      echo "backup: $f -> ${f}.${STAMP_SUFFIX}"
    fi
  }
  install_dir(){
    local d="$1" owner="$2" mode="$3"
    install -d -m "$mode" "$d"
    chown "$owner" "$d" || true
  }
  write_file(){
    local f="$1"
    install -d -m 0755 "$(dirname "$f")"
    printf '%s' "${KZ_CONTENT}" >"$f"
  }

  say "1) Backups der relevanten Konfigurationsdateien (*.${STAMP_SUFFIX})"
  for f in \
    /etc/asterisk/pjsip.conf \
    /etc/asterisk/extensions.conf \
    /etc/asterisk/rtp.conf
  do
    backup_file "$f"
  done

  say "2) Spool-Verzeichnisse + Rechte"
  install_dir "$SPOOL_TIFF_DIR" asterisk:asterisk 0755
  install_dir "$SPOOL_PDF_DIR"  asterisk:asterisk 0755

  say "3) /etc/asterisk/rtp.conf schreiben"
  KZ_CONTENT="$(cat <<EOF
[general]
rtpstart=${RTP_START}
rtpend=${RTP_END}
icesupport=no
strictrtp=yes
EOF
)"
  write_file /etc/asterisk/rtp.conf

  say "4) /etc/asterisk/pjsip.conf schreiben"
  local LOCAL_NET_LINES=""
  local n
  for n in "${LOCAL_NETS[@]}"; do
    LOCAL_NET_LINES+=$'local_net = '"$n"$'\n'
  done

  KZ_CONTENT="$(cat <<EOF
[transport-udp]
type=transport
protocol=udp
bind=${SIP_BIND_IP}:${SIP_BIND_PORT}

external_signaling_address = ${PUBLIC_FQDN_LOCAL}
external_media_address     = ${PUBLIC_FQDN_LOCAL}

${LOCAL_NET_LINES%$'\n'}

[1und1]
type=registration
transport=transport-udp
outbound_auth=1und1-auth
server_uri=${SIP_SERVER_URI}
client_uri=${SIP_CLIENT_URI}
contact_user=${SIP_CONTACT_USER}
retry_interval=60
forbidden_retry_interval=600
expiration=300

[1und1-auth]
type=auth
auth_type=userpass
username=${SIP_USERNAME}
password=${SIP_PASSWORD_LOCAL}

[1und1-aor]
type=aor
contact=${SIP_SERVER_URI}

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

from_user=${FROM_USER}
from_domain=${FROM_DOMAIN}

send_pai=yes
send_rpid=yes
trust_id_outbound=yes

[1und1-identify]
type=identify
endpoint=1und1-endpoint
match=${PROVIDER_MATCH_NET}
EOF
)"
  write_file /etc/asterisk/pjsip.conf

  say "5) /etc/asterisk/extensions.conf schreiben (UniqueID Zählerteil)"
  KZ_CONTENT="$(cat <<'EOF'
[general]
static=yes
writeprotect=no
clearglobalvars=no


[fax-out]

exten => kfx_missing_file,1,NoOp(FAX OUT ERROR: missing KFX_FILE | jobid=${KFX_JOBID})
 same => n,Hangup()

; 49... -> 0...
exten => _49X.,1,NoOp(FAX OUT normalize 49... -> national | jobid=${KFX_JOBID} file=${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,Set(NORM=0${EXTEN:2})
 same => n,NoOp(NORMALIZED=${NORM})
 same => n,GotoIf($[ "${KFX_FILE}" = "" ]?kfx_missing_file,1)

 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,Set(CALLERID(num)=4923319265248)
 same => n,Set(CALLERID(name)=Fax)
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 ; ✅ g: nach Dial weiterlaufen (auch bei BUSY/CONGEST)
 ; ✅ U: SendFAX auf dem PJSIP-Channel mit korrekten Args
 same => n,Dial(PJSIP/${NORM}@1und1-endpoint,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))

 ; ✅ Fax-Result kommt aus MASTER_CHANNEL Variablen (vom PJSIP-Leg gesetzt)
 same => n,NoOp(FAX OUT post-dial | jobid=${KFX_JOBID} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE} KFX_FAXSTATUS=${KFX_FAXSTATUS} KFX_FAXERROR=${KFX_FAXERROR})
 same => n,AGI(kfx_update_status.agi,${KFX_JOBID},${DIALSTATUS},${HANGUPCAUSE},${KFX_FAXSTATUS},${KFX_FAXERROR},${KFX_FAXPAGES},${KFX_FAXBITRATE},${KFX_FAXECM})
 same => n,Hangup()

; national 0...
exten => _0X.,1,NoOp(FAX OUT national | jobid=${KFX_JOBID} file=${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,GotoIf($[ "${KFX_FILE}" = "" ]?kfx_missing_file,1)

 same => n,Set(FAXOPT(ecm)=__FAX_ECM__)
 same => n,Set(FAXOPT(maxrate)=__FAX_MAXRATE__)
 same => n,Set(CALLERID(num)=__FROM_USER__)
 same => n,Set(CALLERID(name)=Fax)
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 same => n,Dial(PJSIP/${EXTEN}@1und1-endpoint,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))

 same => n,NoOp(FAX OUT post-dial | jobid=${KFX_JOBID} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE} KFX_FAXSTATUS=${KFX_FAXSTATUS} KFX_FAXERROR=${KFX_FAXERROR})
 same => n,AGI(kfx_update_status.agi,${KFX_JOBID},${DIALSTATUS},${HANGUPCAUSE},${KFX_FAXSTATUS},${KFX_FAXERROR},${KFX_FAXPAGES},${KFX_FAXBITRATE},${KFX_FAXECM})
 same => n,Hangup()


[kfx_sendfax]
exten => s,1,NoOp(kfx_sendfax | jobid=${ARG1} file=${ARG2})

 ; SendFAX kann non-zero zurückgeben -> TryExec hält den Dialplan am Leben
 same => n,TryExec(SendFAX(${ARG2}))

 ; jetzt sind FAX* Variablen gesetzt (SUCCESS/FAILED + error + pages ...)
 same => n,NoOp(FAX done | FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} FAXPAGES=${FAXPAGES} FAXBITRATE=${FAXBITRATE} FAXECM=${FAXECM})

 ; Ergebnis zurück auf MASTER (Local) damit Post-Dial-AGI es sieht
 same => n,Set(MASTER_CHANNEL(KFX_FAXSTATUS)=${FAXSTATUS})
 same => n,Set(MASTER_CHANNEL(KFX_FAXERROR)=${FAXERROR})
 same => n,Set(MASTER_CHANNEL(KFX_FAXPAGES)=${FAXPAGES})
 same => n,Set(MASTER_CHANNEL(KFX_FAXBITRATE)=${FAXBITRATE})
 same => n,Set(MASTER_CHANNEL(KFX_FAXECM)=${FAXECM})

 same => n,Return()




[fax-in]
exten => __FAX_DID__,1,NoOp(Inbound Fax)
 same => n,Answer()
 same => n,Set(FAXOPT(ecm)=__FAX_ECM__)
 same => n,Set(FAXOPT(maxrate)=__FAX_MAXRATE__)
 same => n,Set(JITTERBUFFER(adaptive)=default)

 same => n,Set(FAXSTAMP=${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)})
 same => n,Set(FROMRAW=${CALLERID(num)})
 same => n,Set(FROM=${FILTER(0-9,${FROMRAW})})
 same => n,ExecIf($["${FROM}"=""]?Set(FROM=unknown))

 same => n,Set(UID=${CUT(UNIQUEID,.,2)})
 same => n,ExecIf($["${UID}"=""]?Set(UID=${UNIQUEID}))

 same => n,Set(FAXBASE=${FAXSTAMP}_${FROM}_${UID})
 same => n,Set(TIFF=__SPOOL_TIFF_DIR__/${FAXBASE}.tif)
 same => n,Set(PDF=__SPOOL_PDF_DIR__/${FAXBASE}.pdf)

 same => n,ReceiveFAX(${TIFF})
 same => n,NoOp(FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} PAGES=${FAXPAGES})

 same => n,Set(HASFILE=${STAT(e,${TIFF})})
 same => n,Set(SIZE=${STAT(s,${TIFF})})
 same => n,GotoIf($[${HASFILE} & ${SIZE} > 0]?to_pdf:no_file)

 same => n(to_pdf),System(tiff2pdf -o ${PDF} ${TIFF})
 same => n,GotoIf($["${SYSTEMSTATUS}"="SUCCESS"]?cleanup:keep_tiff)

 same => n(cleanup),System(rm -f ${TIFF})
 same => n,Hangup()

 same => n(keep_tiff),NoOp(PDF failed or partial - keeping TIFF: ${TIFF})
 same => n,Hangup()

 same => n(no_file),NoOp(No TIFF created. Nothing to convert.)
 same => n,Hangup()
EOF
)"
  KZ_CONTENT="${KZ_CONTENT//__FAX_ECM__/${FAX_ECM}}"
  KZ_CONTENT="${KZ_CONTENT//__FAX_MAXRATE__/${FAX_MAXRATE}}"
  KZ_CONTENT="${KZ_CONTENT//__FROM_USER__/${FROM_USER}}"
  KZ_CONTENT="${KZ_CONTENT//__FAX_DID__/${FAX_DID_LOCAL}}"
  KZ_CONTENT="${KZ_CONTENT//__SPOOL_TIFF_DIR__/${SPOOL_TIFF_DIR}}"
  KZ_CONTENT="${KZ_CONTENT//__SPOOL_PDF_DIR__/${SPOOL_PDF_DIR}}"
  write_file /etc/asterisk/extensions.conf

  say "6) Asterisk restart"
  systemctl restart asterisk.service || true
}

sep "GANZ AM ENDE: Asterisk-Konfiguration"
kienzlefax_bootstrap_asterisk_configs

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

python3 - <<'PY'
import os, io, math, datetime
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm

# Prefer pypdf (new), fallback to PyPDF2 (old)
try:
    from pypdf import PdfReader, PdfWriter
except Exception:
    from PyPDF2 import PdfReader, PdfWriter  # type: ignore

IN = os.environ.get("INFILE")
OUT = os.environ.get("OUTFILE")

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

    # Left: date
    c.drawString(left_x, y, date_str)

    # Center: practice name
    c.drawCentredString(w / 2.0, y, PRACTICE_NAME)

    # Right: page counter
    c.drawRightString(right_x, y, f"Seite {i}/{total}")

    c.showPage()
    c.save()

    packet.seek(0)
    overlay_reader = PdfReader(packet)
    overlay_page = overlay_reader.pages[0]

    # Merge overlay onto original page
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

# ------------------------------------------------------------------------------
# 11) Noch weiterer Kram!!
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 12) kfx
# ------------------------------------------------------------------------------




set -euxo pipefail

cat >/var/lib/asterisk/agi-bin/kfx_update_status.agi <<'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kfx_update_status.agi — kienzlefax
Version: 1.3.3
Stand:  2026-02-16
Autor:  Dr. Thomas Kienzle

Fixes in 1.3.3:
- Retry-Policy wie gewünscht:
  - BUSY:      15 Versuche, 90s Abstand
  - NOANSWER:   3 Versuche, 120s Abstand (wenn du 90s willst: unten ändern)
  - alles andere retryable: 30 Versuche
    - CONGESTION/CHANUNAVAIL: 20s Abstand
    - FAXFAIL (ANSWER aber FAXSTATUS != SUCCESS): 60s Abstand
- OK nur wenn FAXSTATUS == SUCCESS, sonst FAILED oder RETRY nach Policy.
"""

import json
import os
import sys
import re
from pathlib import Path
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, Optional, Tuple, List

BASE = Path("/srv/kienzlefax")
PROC = BASE / "processing"
QUEUE = BASE / "queue"

# gewünschte Retry-Policy
RETRY_RULES = {
    "BUSY":       {"delay": 90,  "max": 15},
    "NOANSWER":   {"delay": 120, "max": 3},    # <-- wenn du 90s willst: 120 -> 90
    "CONGESTION": {"delay": 20,  "max": 30},
    "CHANUNAVAIL":{"delay": 20,  "max": 30},
    # "alles andere": zusätzlich Fax-Fehler nach ANSWER
    "FAXFAIL":    {"delay": 60,  "max": 30},
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

def write_json(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, p)

def apply_retry(job: Dict[str, Any], key: str) -> None:
    rule = RETRY_RULES[key]
    delay = int(rule["delay"])
    mx = int(rule["max"])

    r = job.setdefault("retry", {})
    try:
        r["attempt"] = int(r.get("attempt") or 0) + 1
    except Exception:
        r["attempt"] = 1
    r["max"] = mx
    r["last_reason"] = key
    r["suggested_delay_sec"] = delay
    r["next_try_at"] = (datetime.now(timezone.utc) + timedelta(seconds=delay)).replace(microsecond=0).isoformat()

def main() -> int:
    _agi_env = agi_read_env()

    args = sys.argv[1:]
    while len(args) < 8:
        args.append("")

    jobid = sanitize_jobid(args[0])
    dialstatus = upper(args[1])
    hangupcause = to_str(args[2]).strip()
    faxstatus = upper(args[3])
    faxerror = to_str(args[4]).strip()
    faxpages_raw = to_str(args[5]).strip()
    faxbitrate = to_str(args[6]).strip()
    faxecm = to_str(args[7]).strip()

    if not jobid:
        eprint("kfx_update_status.agi: missing jobid (ARG1)")
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

    res = job.setdefault("result", {})
    res["dialstatus"] = dialstatus
    res["hangupcause"] = hangupcause
    res["faxstatus"] = faxstatus
    res["faxerror"] = faxerror
    res["faxpages_raw"] = faxpages_raw
    res["faxbitrate"] = faxbitrate
    res["faxecm"] = faxecm

    sent, total = parse_pages(faxpages_raw)
    if sent is not None:
        res["faxpages_sent"] = sent
    if total is not None:
        res["faxpages_total"] = total

    # Klassifikation
    status = "FAILED"
    reason = ""

    if was_cancelled or dialstatus == "CANCEL":
        status = "FAILED"
        reason = "cancelled"
    elif faxstatus == "SUCCESS":
        status = "OK"
        reason = "OK"
    else:
        retry_key: Optional[str] = None

        # dialstatus-basierte retries
        if dialstatus in ("BUSY", "NOANSWER", "CONGESTION", "CHANUNAVAIL"):
            retry_key = dialstatus

        # Faxfehler nach ANSWER => "alles andere": retrybar als FAXFAIL
        elif dialstatus == "ANSWER":
            retry_key = "FAXFAIL"

        if retry_key and retry_key in RETRY_RULES:
            status = "RETRY"
            reason = retry_key
            apply_retry(job, retry_key)
        else:
            status = "FAILED"
            reason = faxstatus or dialstatus or "unknown"

    job["status"] = status
    res["reason"] = reason

    job["end_time"] = now_iso()
    job["updated_at"] = job["end_time"]
    if status in ("OK", "FAILED"):
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]

    try:
        write_json(jp, job)
    except Exception as e:
        eprint(f"kfx_update_status.agi: cannot write {jp}: {e}")

    try:
        agi_send(f'SET VARIABLE KFX_JOB_STATUS "{status}"')
    except Exception:
        pass

    return 0

if __name__ == "__main__":
    sys.exit(main())
EOF


chmod 0755 /var/lib/asterisk/agi-bin/kfx_update_status.agi

# ------------------------------------------------------------------------------
# 13) noch paar packages
# ------------------------------------------------------------------------------


apt-get update
apt-get install -y python3 qpdf ghostscript python3-reportlab python3-pypdf


# ------------------------------------------------------------------------------
# 14) worker
# ------------------------------------------------------------------------------


set -euxo pipefail

cat >/usr/local/bin/kienzlefax-worker.py <<'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kienzlefax-worker.py — Asterisk-Only Worker (SendFAX)
Version: 1.3.3
Stand:  2026-02-16
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
  - HylaFAX-Legacy entfernt: Finalisierung basiert ausschließlich auf AGI-Ergebnis in job.json
    (kfx_update_status.agi schreibt status=OK/FAILED/RETRY + result.*).
  - Retry-Handling: status=RETRY => zurück in Queue (Backoff via retry.next_try_at, attempt, etc.).
  - Cooldown nach jedem Call-Ende (terminal oder RETRY) für Gerätepause.
  - Asterisk-Originate so implementiert, dass fax-out NICHT doppelt ausgeführt wird:
    Local/<exten>@<context>/n + Application=Wait (kein Context/Exten/Priority im AMI-Action).
  - PDF->TIFF/F Konvertierung (tiffg4) für SendFAX.
  - Report+Dokument werden weiterhin als PDF zusammengeführt (qpdf), für Archiv/Fehler.
- 1.3.3:
  - Retry-Limits werden erzwungen:
    Wenn job.status=RETRY und retry.max gesetzt ist und attempt >= max -> endgültig FAILED + Fehlerarchiv.
    (Policy/Max/Delay kommt aus kfx_update_status.agi v1.3.3)
  - Report enthält Retry-Infos (attempt/max/next_try_at), wenn vorhanden.

Voraussetzungen:
- Dialplan:
  - fax-out Kontext erwartet KFX_JOBID, KFX_FILE (TIFF) und ruft am Ende:
    AGI(kfx_update_status.agi,jobid,dialstatus,hangupcause,kfx_faxstatus,kfx_faxerror,kfx_faxpages,kfx_faxbitrate,kfx_faxecm)
  - kfx_sendfax nutzt TryExec(SendFAX(...)) und setzt MASTER_CHANNEL(KFX_FAX*) (damit Post-Dial AGI Werte sieht).
- /var/lib/asterisk/agi-bin/kfx_update_status.agi vorhanden (v1.3.3).
- AMI Manager-User kfx mit originate/write Rechte.
- Pakete: python3, qpdf, ghostscript, python3-reportlab
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
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, Dict, Optional, Tuple, List


# ----------------------------
# Config (defaults; can be overridden via env)
# ----------------------------
BASE = Path(os.environ.get("KFX_BASE", "/srv/kienzlefax"))
QUEUE = BASE / "queue"
PROC = BASE / "processing"
ARCH_OK = BASE / "sendeberichte"
FAIL_IN = BASE / "sendefehler" / "eingang"
FAIL_OUT = BASE / "sendefehler" / "berichte"

# Asterisk AMI
AMI_HOST = os.environ.get("KFX_AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("KFX_AMI_PORT", "5038"))
AMI_USER = os.environ.get("KFX_AMI_USER", "kfx")
AMI_PASS = os.environ.get("KFX_AMI_PASS", "")
DIAL_CONTEXT = os.environ.get("KFX_DIAL_CONTEXT", "fax-out")

# Tools
QPDF_BIN = os.environ.get("KFX_QPDF_BIN", "qpdf")
GS_BIN = os.environ.get("KFX_GS_BIN", "gs")
PDF_HEADER_SCRIPT = Path(os.environ.get("KFX_PDF_HEADER_SCRIPT", "/usr/local/bin/pdf_with_header.sh"))

# Concurrency/Timing
MAX_INFLIGHT_PROCESSING = int(os.environ.get("KFX_MAX_INFLIGHT", "1"))
POLL_INTERVAL_SEC = float(os.environ.get("KFX_POLL_INTERVAL_SEC", "1.0"))
POST_CALL_COOLDOWN_SEC = float(os.environ.get("KFX_POST_CALL_COOLDOWN_SEC", "5.0"))

# Fax conversion defaults
TIFF_DPI = os.environ.get("KFX_TIFF_DPI", "204x196")
TIFF_DEVICE = os.environ.get("KFX_TIFF_DEVICE", "tiffg4")

# Lockfile (reboot-safe via flock)
LOCKFILE = BASE / ".kienzlefax-worker.lock"

LOG_PREFIX = "kienzlefax-worker"

_lock_fd: Optional[int] = None
_next_submit_ts: float = 0.0


# ----------------------------
# Helpers
# ----------------------------
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
    """Optional header overlay; returns pdf to use for sending/archiving."""
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
    """
    Convert PDF to TIFF/F (Group4) for Asterisk SendFAX.
    Produces multi-page TIFF.
    """
    cmd = [
        GS_BIN,
        "-q",
        "-dNOPAUSE",
        "-dBATCH",
        "-dSAFER",
        f"-sDEVICE={TIFF_DEVICE}",
        f"-r{TIFF_DPI}",
        "-sPAPERSIZE=a4",
        "-dFIXEDMEDIA",
        "-dPDFFitPage",
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
        st = str(job.get("status") or "").lower()
        if st in ("claimed", "submitted", "running"):
            n += 1
    return n

def get_busy_numbers() -> set[str]:
    """
    Avoid sending multiple jobs to same number in parallel.
    """
    busy: set[str] = set()
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        st = str(job.get("status") or "").lower()
        if st in ("claimed", "submitted", "running", "retry_wait"):
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

        # backoff
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


# ----------------------------
# Reporting
# ----------------------------
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
    r_attempt = retry.get("attempt")
    r_max = retry.get("max")
    r_next = retry.get("next_try_at")
    r_last = retry.get("last_reason")

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

    if r_attempt is not None or r_max is not None or r_next or r_last:
        c.drawString(50, y, f"Retry: attempt={r_attempt} max={r_max} last_reason={r_last or ''}")
        y -= 16
        if r_next:
            c.drawString(50, y, f"Next try at (UTC): {r_next}")
            y -= 16

    started = job.get("started_at") or job.get("submitted_at") or job.get("claimed_at")
    ended = job.get("end_time") or job.get("finalized_at")
    if started and ended:
        try:
            s = datetime.fromisoformat(str(started).replace("Z", "+00:00"))
            e = datetime.fromisoformat(str(ended).replace("Z", "+00:00"))
            dur = int((e - s).total_seconds())
            c.drawString(50, y, f"Dauer: {dur} s")
            y -= 16
        except Exception:
            pass

    c.setFont("Helvetica", 9)
    c.drawString(50, 40, f"Erzeugt: {now_iso()}  |  kienzlefax-worker v1.3.3")
    c.showPage()
    c.save()


# ----------------------------
# AMI client (minimal)
# ----------------------------
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
    """
    Avoid double dialplan execution:
    - Channel is Local/<exten>@<context>/n (Local triggers dialplan itself)
    - Do NOT set Context/Exten/Priority in AMI action
    - Use Application=Wait to satisfy Originate
    """
    if not AMI_PASS:
        raise AmiError("AMI password missing (KFX_AMI_PASS)")

    action_id = f"kfx-{jobid}"
    channel = f"Local/{exten}@{DIAL_CONTEXT}/n"

    s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
    sockf = s.makefile("rwb", buffering=0)
    try:
        _ = sockf.readline()  # banner
        ami_login(sockf)

        ami_send(sockf, "Action: Originate")
        ami_send(sockf, f"ActionID: {action_id}")
        ami_send(sockf, f"Channel: {channel}")
        ami_send(sockf, "Async: true")

        ami_send(sockf, "Application: Wait")
        ami_send(sockf, "Data: 1")

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
            try:
                sockf.close()
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass


# ----------------------------
# Workflow: prepare/submit/finalize/retry
# ----------------------------
def prepare_send_files(jobdir: Path, job: Dict[str, Any]) -> Tuple[Path, Path]:
    """
    Returns (pdf_for_archive, tiff_for_send).
    """
    pdf_in = find_original_pdf_in_jobdir(jobdir)
    if not pdf_in:
        raise RuntimeError("missing doc.pdf/source.pdf")

    pdf_for_archive = add_header_pdf(pdf_in)

    tiff = jobdir / "doc.tif"
    if (not tiff.exists()) or (tiff.stat().st_size == 0):
        pdf_to_tiff_g4(pdf_for_archive, tiff)

    return pdf_for_archive, tiff

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

    rec = job.get("recipient") or {}
    number = normalize_number(rec.get("number") or "")
    if not number:
        raise RuntimeError("invalid recipient number")

    pdf_for_archive, tiff = prepare_send_files(jobdir, job)

    job["claimed_at"] = job.get("claimed_at") or now_iso()
    job["submitted_at"] = now_iso()
    job["started_at"] = job.get("started_at") or job["submitted_at"]
    job["status"] = "submitted"

    job.setdefault("asterisk", {})
    job["asterisk"]["dial_context"] = DIAL_CONTEXT
    job["asterisk"]["exten"] = number
    job["asterisk"]["tiff"] = str(tiff)
    job["asterisk"]["pdf_for_archive"] = str(pdf_for_archive)

    write_json(jp, job)

    try:
        ami_originate_local(jobid=str(job.get("job_id") or jobdir.name),
                            exten=number,
                            tiff_path=str(tiff))
        log(f"submitted via AMI -> {jobdir.name} exten={number}")
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
    """
    status=RETRY => move back to queue (worker respects retry.next_try_at for backoff).
    """
    job["status"] = "retry_wait"
    job["updated_at"] = now_iso()
    write_json(jobdir / "job.json", job)

    target = QUEUE / jobdir.name
    try:
        jobdir.rename(target)
        r = job.get("retry") or {}
        log(f"retry scheduled attempt={r.get('attempt','?')}/{r.get('max','?')} "
            f"reason={r.get('last_reason','')} next_try_at={r.get('next_try_at','')} -> {target.name}")
    except Exception as e:
        log(f"retry move back to queue failed for {jobdir.name}: {e}")

def step_finalize_processing() -> None:
    """
    Finalize processing jobs based on job.json status written by AGI.
    """
    global _next_submit_ts

    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue

        st = str(job.get("status") or "").upper()

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

        # RETRY: either requeue, or hard-fail if attempt>=max
        if st in ("RETRY", "RETRY_WAIT"):
            try:
                r = job.get("retry") or {}
                attempt = int(r.get("attempt") or 0)
                mx = int(r.get("max") or 0)

                if mx > 0 and attempt >= mx:
                    # terminal failure: max retries reached
                    job["status"] = "FAILED"
                    job.setdefault("result", {})
                    base_reason = str((job.get("result") or {}).get("reason") or "RETRY")
                    job["result"]["reason"] = f"{base_reason} (max retries reached: {attempt}/{mx})"
                    job["finalized_at"] = job.get("finalized_at") or now_iso()
                    job["end_time"] = job.get("end_time") or job["finalized_at"]
                    write_json(jp, job)
                    finalize_failed(jdir, job)
                    shutil.rmtree(jdir, ignore_errors=True)
                    _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
                    continue

                # otherwise requeue
                requeue_retry(jdir, job)
            except Exception as e:
                log(f"requeue exception {jdir.name}: {e}")

            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

        # Otherwise: claimed/submitted/running -> keep waiting for AGI to set status

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
            job["status"] = job.get("status") or "claimed"
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


# ----------------------------
# Main
# ----------------------------
def main() -> None:
    ensure_dirs()
    acquire_lock()
    log("started (v1.3.3)")
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
EOF

chown root:root /usr/local/bin/kienzlefax-worker.py
chmod 0755 /usr/local/bin/kienzlefax-worker.py

ls -lah /usr/local/bin/kienzlefax-worker.py
head -n 40 /usr/local/bin/kienzlefax-worker.py










echo
echo "======================================================================"
echo "INSTALLER DONE."
echo "Web:  http://<host>/kienzlefax.php"
echo "======================================================================"

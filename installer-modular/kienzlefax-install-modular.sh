#!/usr/bin/env bash
# ==============================================================================
# kienzlefax-install-modular.sh
#
# Modularer Installer (alles wird installiert; keine optionalen Module)
#
# Version: 3.0.0
# Stand:   2026-02-18
# Autor:   Dr. Thomas Kienzle
#
# Enthält:
# - Parameterabfrage wie im "alten" Installer (plus SIP_BIND_PORT default 5070 + Hostname)
# - apt-get update + apt-get -y upgrade
# - Pakete (übernommen/angelehnt an alten Installer; ergänzt um benötigte Tools)
# - Web: kienzlefax.php + faxton.mp3 + index.html refresh
# - Apache SSL: self-signed 50 Jahre, Hostname als CN+SAN, Hostname setzen
# - Admin-User (passwd) + Samba (smbpasswd)
# - CUPS Backend + fax1..fax5 + Bonjour/DNS-SD + Samba Shares (inkl. fax-eingang)
# - Asterisk Build aus Git (interaktiv: make menuselect) + systemd enable
# - Asterisk Config via Remote-Module:
#     * pjsip-1und1.sh  (PJSIP komplett/Provider, inkl. bind-port)
#     * extensions.sh   (Dialplan)
#     * worker.sh       (Worker + AGI + service)
# - pdf_with_header.sh via Remote-Module
#
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Konstanten / URLs (Remote Module)
# ------------------------------------------------------------------------------
MOD_BASE="/usr/local/lib/kienzlefax-installer"
MOD_LIB="${MOD_BASE}/lib"
MOD_DIR="${MOD_BASE}/modules"
MOD_CACHE="${MOD_BASE}/cache"
STATE_DIR="/var/lib/kienzlefax-installer"

# Remote module URLs (wie im neuen Script gesetzt)
URL_EXTENSIONS="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/extensions.sh"
URL_WORKER="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/worker.sh"
URL_PJSIP_1UND1="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pjsip-1und1.sh"
URL_PDF_WITH_HEADER="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pdf_with_header.sh"

# Web bootstrap
WEBROOT="/var/www/html"
WEB_URL_RAW="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax.php"
FAXTON_URL="https://github.com/thomaskien/kienzlefax-fuer-linux/raw/refs/heads/main/faxton.mp3"

# Project paths
KZ_BASE="/srv/kienzlefax"
SPOOL_TIFF_DIR="/var/spool/asterisk/fax1"
SPOOL_PDF_DIR="/var/spool/asterisk/fax"

# Asterisk build (Git)
ASTERISK_SRC_DIR="/usr/src/asterisk"
ASTERISK_GIT_URL="https://github.com/asterisk/asterisk.git"
ASTERISK_GIT_REF_DEFAULT="20"   # LTS branch default

# AMI fixed
KFX_AMI_USER="kfx"
KFX_AMI_BINDADDR="127.0.0.1"
KFX_AMI_PORT="5038"

# Defaults
DEFAULT_SIP_BIND_PORT="5070"
DEFAULT_RTP_START="12000"
DEFAULT_RTP_END="12049"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

require_root(){ [[ ${EUID:-0} -eq 0 ]] || die "Bitte als root ausführen."; }

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

sanitize_digits(){ echo "$1" | tr -cd '0-9'; }

backup_file_ts(){
  local f="$1"
  local stamp=".old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}${stamp}"
    log "backup: $f -> ${f}${stamp}"
  fi
}

ask_default(){
  # usage: ask_default VAR "Prompt" "default"
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __def="$1"; shift
  local __val=""
  read -r -p "${__prompt} [${__def}]: " __val
  __val="${__val:-$__def}"
  printf -v "$__var" "%s" "$__val"
}

ask_yes_no(){
  # usage: ask_yes_no VAR "Prompt" "y|n(default)"
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __def="$1"; shift
  local __val=""
  while true; do
    read -r -p "${__prompt} [${__def}]: " __val
    __val="${__val:-$__def}"
    case "$__val" in
      y|Y|yes|YES) printf -v "$__var" "y"; return 0;;
      n|N|no|NO)   printf -v "$__var" "n"; return 0;;
      *) echo "Bitte y/n eingeben.";;
    esac
  done
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

download_to(){
  # usage: download_to URL OUTFILE
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  curl -fsSL "$url" -o "$out"
  [[ -s "$out" ]] || die "Download leer/fehlgeschlagen: $url"
}

run_module(){
  # usage: run_module /path/to/module.sh
  local m="$1"
  [[ -x "$m" ]] || die "Modul nicht ausführbar: $m"
  log "[RUN] $m"
  "$m"
  log "[OK ] $m"
}

# ------------------------------------------------------------------------------
# Bootstrap local module files (small ones) into MOD_DIR
# ------------------------------------------------------------------------------
bootstrap_local_modules(){
  mkdir -p "$MOD_BASE" "$MOD_LIB" "$MOD_DIR" "$MOD_CACHE" "$STATE_DIR"

  # 00-base: parameter prompts + hostname set + env export file
  cat >"${MOD_DIR}/00-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

read_secret_twice(){
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

sanitize_digits(){ echo "$1" | tr -cd '0-9'; }

ask_default(){
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __def="$1"; shift
  local __val=""
  read -r -p "${__prompt} [${__def}]: " __val
  __val="${__val:-$__def}"
  printf -v "$__var" "%s" "$__val"
}

backup_file_ts(){
  local f="$1"
  local stamp=".old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}${stamp}"
    log "backup: $f -> ${f}${stamp}"
  fi
}

sep "Hostname + Provider-Parameter abfragen (GANZ AM ANFANG)"

# Hostname (für Maschine + Zertifikat)
read -r -p "Hostname für diese Maschine (z.B. fax): " KFX_HOSTNAME
[[ -n "${KFX_HOSTNAME}" ]] || die "Hostname darf nicht leer sein."

# Set hostname
hostnamectl set-hostname "${KFX_HOSTNAME}"

# /etc/hosts konsistent halten (127.0.1.1 Zeile)
backup_file_ts /etc/hosts
if grep -qE '^\s*127\.0\.1\.1\s+' /etc/hosts; then
  sed -i -E "s/^\s*127\.0\.1\.1\s+.*/127.0.1.1\t${KFX_HOSTNAME}/" /etc/hosts
else
  echo -e "127.0.1.1\t${KFX_HOSTNAME}" >> /etc/hosts
fi

# Provider Parameter (wie alter Installer)
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

# SIP bind port EINMAL abfragen (default 5070)
ask_default SIP_BIND_PORT "SIP Bind Port (PJSIP, extern; für Provider-Config)" "${DEFAULT_SIP_BIND_PORT:-5070}"
[[ "$SIP_BIND_PORT" =~ ^[0-9]+$ ]] || die "SIP_BIND_PORT ungültig"

# RTP range (wie neuer Installer; default 12000-12049)
ask_default RTP_START "RTP Start-Port" "${DEFAULT_RTP_START:-12000}"
ask_default RTP_END   "RTP End-Port"   "${DEFAULT_RTP_END:-12049}"
[[ "$RTP_START" =~ ^[0-9]+$ ]] || die "RTP_START ungültig"
[[ "$RTP_END" =~ ^[0-9]+$ ]] || die "RTP_END ungültig"
[ "$RTP_START" -lt "$RTP_END" ] || die "RTP_START muss < RTP_END sein"

# Asterisk Git ref (default 20)
ask_default AST_REF "Asterisk Git-Ref (Branch/Tag/Commit) für Build" "${ASTERISK_GIT_REF_DEFAULT:-20}"

# Persist env for later modules
ENVFILE="/etc/kienzlefax-installer.env"
cat >"$ENVFILE" <<EENV
# generated by kienzlefax installer
KFX_HOSTNAME=${KFX_HOSTNAME}
KFX_PUBLIC_FQDN=${PUBLIC_FQDN}
KFX_SIP_NUMBER=${SIP_NUMBER}
KFX_SIP_PASSWORD=${SIP_PASSWORD}
KFX_FAX_DID=${FAX_DID}
KFX_AMI_SECRET=${AMI_SECRET}
KFX_SIP_BIND_PORT=${SIP_BIND_PORT}
KFX_RTP_START=${RTP_START}
KFX_RTP_END=${RTP_END}
KFX_AST_REF=${AST_REF}
EENV
chmod 0600 "$ENVFILE"

log "[OK] Parameter gesetzt:"
log " - Hostname=${KFX_HOSTNAME}"
log " - PUBLIC_FQDN=${PUBLIC_FQDN}"
log " - SIP_NUMBER=${SIP_NUMBER}"
log " - FAX_DID=${FAX_DID}"
log " - SIP_BIND_PORT=${SIP_BIND_PORT}"
log " - RTP=${RTP_START}-${RTP_END}"
log " - AST_REF=${AST_REF}"
log " - AMI: 127.0.0.1:5038 user=kfx (secret gesetzt)"
EOF
  chmod +x "${MOD_DIR}/00-base.sh"

  # 10-packages
  cat >"${MOD_DIR}/10-packages.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

export DEBIAN_FRONTEND=noninteractive

sep "System aktualisieren + Pakete installieren (gebündelt)"

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
  python3 python3-venv python3-pip python3-reportlab \
  sox lame \
  build-essential git pkg-config autoconf automake libtool \
  libxml2-dev libncurses5-dev libedit-dev uuid-dev \
  libssl-dev libsqlite3-dev \
  libsrtp2-dev \
  libtiff-dev \
  libjansson-dev \
  libspandsp-dev

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
EOF
  chmod +x "${MOD_DIR}/10-packages.sh"

  # 20-dirs-acl
  cat >"${MOD_DIR}/20-dirs-acl.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

KZ_BASE="/srv/kienzlefax"
SPOOL_TIFF_DIR="/var/spool/asterisk/fax1"
SPOOL_PDF_DIR="/var/spool/asterisk/fax"

sep "Basis-Verzeichnisse + Gruppe/ACL"

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
mkdir -p "${KZ_BASE}/staging" "${KZ_BASE}/queue" "${KZ_BASE}/processing"

# Archiv
mkdir -p "${KZ_BASE}/sendeberichte"

# Telefonbuch-DB Platzhalter
touch "${KZ_BASE}/phonebook.sqlite"

# Asterisk fax-in spools
mkdir -p "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}"
chmod 0777 "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}" || true

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
chmod 2777 "${KZ_BASE}/sendefehler" "${KZ_BASE}/sendefehler/eingang" "${KZ_BASE}/sendefehler/berichte"

chmod 2775 "${KZ_BASE}/staging" "${KZ_BASE}/queue" "${KZ_BASE}/processing"
chmod 2770 "${KZ_BASE}/sendeberichte"

# ACL: lp + gruppe dürfen in incoming schreiben
setfacl -m u:lp:rwx,g:kienzlefax:rwx "${KZ_BASE}/incoming" "${KZ_BASE}/incoming"/fax{1..5} || true
setfacl -d -m u:lp:rwx,g:kienzlefax:rwx "${KZ_BASE}/incoming" "${KZ_BASE}/incoming"/fax{1..5} || true

# Default ACL im Base (praktisch)
setfacl -R -m g:kienzlefax:rwx "${KZ_BASE}" || true
setfacl -R -d -m g:kienzlefax:rwx "${KZ_BASE}" || true

log "[OK] Verzeichnisse/Rechte/ACL erledigt."
EOF
  chmod +x "${MOD_DIR}/20-dirs-acl.sh"

  # 30-admin-user
  cat >"${MOD_DIR}/30-admin-user.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

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
EOF
  chmod +x "${MOD_DIR}/30-admin-user.sh"

  # 40-web-ssl
  cat >"${MOD_DIR}/40-web-ssl.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

WEBROOT="/var/www/html"
WEB_URL_RAW="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax.php"
FAXTON_URL="https://github.com/thomaskien/kienzlefax-fuer-linux/raw/refs/heads/main/faxton.mp3"

sep "Web installieren (kienzlefax.php + faxton.mp3) + index.html redirect"

mkdir -p "${WEBROOT}"
curl -fsSL -o "${WEBROOT}/kienzlefax.php" "${WEB_URL_RAW}"
curl -fsSL -o "${WEBROOT}/faxton.mp3" "${FAXTON_URL}"

cat > "${WEBROOT}/index.html" <<'HTML'
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0; url=/kienzlefax.php">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>KienzleFax</title>
</head>
<body>
  <p>Weiterleitung… <a href="/kienzlefax.php">kienzlefax.php</a></p>
</body>
</html>
HTML

chown www-data:www-data "${WEBROOT}/kienzlefax.php" "${WEBROOT}/faxton.mp3" "${WEBROOT}/index.html" || true
chmod 0644 "${WEBROOT}/kienzlefax.php" "${WEBROOT}/faxton.mp3" "${WEBROOT}/index.html"

sep "Apache SSL: 50 Jahre self-signed (CN+SAN=Hostname) + Site aktivieren"

CERT_DIR="/etc/ssl/kienzlefax"
CERT_KEY="${CERT_DIR}/kienzlefax.key"
CERT_CRT="${CERT_DIR}/kienzlefax.crt"
mkdir -p "$CERT_DIR"
chmod 0700 "$CERT_DIR"

# openssl config for SAN
OPENSSL_CNF="$(mktemp)"
cat >"$OPENSSL_CNF" <<EOCNF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[ dn ]
CN = ${KFX_HOSTNAME}

[ v3_req ]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ alt_names ]
DNS.1 = ${KFX_HOSTNAME}
EOCNF

# Create cert if missing
if [[ ! -s "$CERT_KEY" || ! -s "$CERT_CRT" ]]; then
  openssl req -x509 -nodes -newkey rsa:4096 \
    -days 18250 \
    -keyout "$CERT_KEY" \
    -out "$CERT_CRT" \
    -config "$OPENSSL_CNF"
  chmod 0600 "$CERT_KEY"
  chmod 0644 "$CERT_CRT"
  log "[OK] Zertifikat erstellt: $CERT_CRT (50 Jahre)"
else
  log "[OK] Zertifikat existiert bereits, skip."
fi

rm -f "$OPENSSL_CNF" || true

# Enable SSL module and site
a2enmod ssl >/dev/null 2>&1 || true

# Use default-ssl but point to our cert
SSL_SITE="/etc/apache2/sites-available/default-ssl.conf"
if [[ -f "$SSL_SITE" ]]; then
  cp -a "$SSL_SITE" "${SSL_SITE}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" || true
fi

# Ensure default-ssl exists; if not, create minimal site
if [[ ! -f "$SSL_SITE" ]]; then
  cat >"$SSL_SITE" <<EOFSSL
<IfModule mod_ssl.c>
<VirtualHost _default_:443>
    ServerName ${KFX_HOSTNAME}
    DocumentRoot ${WEBROOT}

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined

    SSLEngine on
    SSLCertificateFile      ${CERT_CRT}
    SSLCertificateKeyFile   ${CERT_KEY}

    <Directory ${WEBROOT}>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
</IfModule>
EOFSSL
else
  # Patch cert paths (conservative)
  sed -i -E "s|^\s*SSLCertificateFile\s+.*|SSLCertificateFile      ${CERT_CRT}|" "$SSL_SITE" || true
  sed -i -E "s|^\s*SSLCertificateKeyFile\s+.*|SSLCertificateKeyFile   ${CERT_KEY}|" "$SSL_SITE" || true
  # Ensure ServerName present (avoid warnings)
  if ! grep -qE '^\s*ServerName\s+' "$SSL_SITE"; then
    sed -i -E "s|<VirtualHost[^>]*>|&\n    ServerName ${KFX_HOSTNAME}|" "$SSL_SITE" || true
  fi
fi

a2ensite default-ssl >/dev/null 2>&1 || true

systemctl enable --now apache2.service
systemctl restart apache2

log "[OK] Web+SSL bereit: https://${KFX_HOSTNAME}/ (self-signed)"
EOF
  chmod +x "${MOD_DIR}/40-web-ssl.sh"

  # 50-cups-samba (backend + printers + shares)
  cat >"${MOD_DIR}/50-cups-samba.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

KZ_BASE="/srv/kienzlefax"
SPOOL_PDF_DIR="/var/spool/asterisk/fax"

WORKGROUP="WORKGROUP"

INCOMING="${KZ_BASE}/incoming"
PDF_ZU_FAX="${KZ_BASE}/pdf-zu-fax"
SENDEFEHLER_EINGANG="${KZ_BASE}/sendefehler/eingang"
SENDEFEHLER_BERICHTE="${KZ_BASE}/sendefehler/berichte"
SENDEBERICHTE="${KZ_BASE}/sendeberichte"

BACKEND="/usr/lib/cups/backend/kienzlefaxpdf"
BACKEND_LOG="/var/log/kienzlefaxpdf-backend.log"

sep "CUPS Backend + fax1..fax5 + Bonjour + Samba Shares (inkl. fax-eingang)"

echo "== cups-browsed deaktivieren (falls vorhanden; verhindert implicitclass://) =="
if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "cups-browsed.service"; then
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

echo "== Samba: smb.conf schreiben (inkl. Shares; inkl. fax-eingang) =="
mkdir -p /var/spool/samba
chmod 1777 /var/spool/samba

# fax-eingang path sicherstellen (Guest share)
mkdir -p "${SPOOL_PDF_DIR}"
chmod 0777 "${SPOOL_PDF_DIR}" || true

cat > /etc/samba/smb.conf <<EOFSMB
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
   read only = yes
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0444
   directory mask = 2777

[sendeberichte]
   path = ${SENDEBERICHTE}
   browseable = yes
   read only = yes
   guest ok = no
   valid users = admin
   force group = kienzlefax
   create mask = 0640
   directory mask = 2750

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
EOFSMB

systemctl enable --now cups || true
systemctl restart cups || true

systemctl enable --now smbd nmbd || true
systemctl restart smbd nmbd || true

systemctl enable --now avahi-daemon || true
systemctl restart avahi-daemon || true

log "[OK] CUPS+Samba fertig."
EOF
  chmod +x "${MOD_DIR}/50-cups-samba.sh"

  # 60-asterisk-build
  cat >"${MOD_DIR}/60-asterisk-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

ASTERISK_SRC_DIR="/usr/src/asterisk"
ASTERISK_GIT_URL="https://github.com/asterisk/asterisk.git"

sep "Asterisk: Source holen + Build (INTERAKTIV menuselect)"

mkdir -p "$(dirname "$ASTERISK_SRC_DIR")"
if [[ ! -d "$ASTERISK_SRC_DIR/.git" ]]; then
  rm -rf "$ASTERISK_SRC_DIR"
  git clone "$ASTERISK_GIT_URL" "$ASTERISK_SRC_DIR"
fi

cd "$ASTERISK_SRC_DIR"
git fetch --all --tags
git checkout -f "$KFX_AST_REF"

make distclean >/dev/null 2>&1 || true
./configure

echo
echo "WICHTIG: Jetzt kommt make menuselect (interaktiv)."
echo "Bitte dort mindestens prüfen/aktivieren:"
echo "  - res_fax"
echo "  - app_fax (SendFAX/ReceiveFAX)"
echo "  - res_fax_spandsp (falls verfügbar/gewünscht)"
echo "  - format_tiff"
echo "  - (optional) codec_ulaw/alaw etc. nach Bedarf"
echo
read -r -p "ENTER drücken um menuselect zu starten..." _

make menuselect

CPU="$(nproc 2>/dev/null || echo 2)"
make -j"$CPU"
make install
make samples || true
make config  || true
ldconfig

systemctl enable --now asterisk
log "[OK] Asterisk installiert/gestartet."
EOF
  chmod +x "${MOD_DIR}/60-asterisk-build.sh"

  # 70-rtp-ami (Manager minimal robust)
  cat >"${MOD_DIR}/70-rtp-ami.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

RTP_CONF="/etc/asterisk/rtp.conf"
MANAGER_CONF="/etc/asterisk/manager.conf"

ini_set_kv(){
  local file="$1"; local section="$2"; local key="$3"; local value="$4"
  touch "$file"
  if ! grep -qE "^\s*\[$section\]\s*$" "$file"; then
    { echo; echo "[$section]"; echo "$key = $value"; } >>"$file"
    return
  fi
  local tmp="${file}.tmp.$$"
  awk -v sec="$section" -v key="$key" -v val="$value" '
    function ltrim(s){ sub(/^[ \t\r\n]+/,"",s); return s }
    function rtrim(s){ sub(/[ \t\r\n]+$/,"",s); return s }
    function trim(s){ return rtrim(ltrim(s)) }
    BEGIN{ insec=0; done=0 }
    {
      line=$0
      if (match(line, /^\s*\[([^\]]+)\]\s*$/, m)) {
        if (insec==1 && done==0) { print key " = " val; done=1 }
        insec = (trim(m[1])==sec) ? 1 : 0
        print line
        next
      }
      if (insec==1) {
        if (match(line, "^[ \t]*" key "[ \t]*=", mm)) {
          if (done==0) { print key " = " val; done=1 }
          next
        }
      }
      print line
    }
    END{ if (insec==1 && done==0) print key " = " val }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

ensure_line_in_file(){
  local file="$1"; local line="$2"
  touch "$file"
  grep -Fxq "$line" "$file" || echo "$line" >>"$file"
}

sep "Asterisk: RTP Range setzen"
cp -a "$RTP_CONF" "${RTP_CONF}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
touch "$RTP_CONF"
ini_set_kv "$RTP_CONF" "general" "rtpstart" "$KFX_RTP_START"
ini_set_kv "$RTP_CONF" "general" "rtpend"   "$KFX_RTP_END"

sep "Asterisk AMI/Manager aktivieren + nur localhost"
cp -a "$MANAGER_CONF" "${MANAGER_CONF}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
touch "$MANAGER_CONF"

ensure_line_in_file "$MANAGER_CONF" '#include "/etc/asterisk/manager.d/*.conf"'
mkdir -p /etc/asterisk/manager.d

ini_set_kv "$MANAGER_CONF" "general" "enabled"    "yes"
ini_set_kv "$MANAGER_CONF" "general" "webenabled" "no"
ini_set_kv "$MANAGER_CONF" "general" "bindaddr"   "127.0.0.1"
ini_set_kv "$MANAGER_CONF" "general" "port"       "5038"

cat >/etc/asterisk/manager.d/kfx.conf <<EOFCONF
[kfx]
secret = ${KFX_AMI_SECRET}

; nur lokal (weil AMI bindaddr=127.0.0.1)
deny=0.0.0.0/0.0.0.0
permit=127.0.0.1/255.255.255.255

read = system,call,log,command,reporting
write = system,call,command,reporting,originate
EOFCONF
chmod 0644 /etc/asterisk/manager.d/kfx.conf
chown root:root /etc/asterisk/manager.d/kfx.conf

asterisk -rx "manager reload" || true
asterisk -rx "manager show settings" | sed -n '1,200p' || true
asterisk -rx "manager show user kfx" || true

log "[OK] RTP+AMI konfiguriert."
EOF
  chmod +x "${MOD_DIR}/70-rtp-ami.sh"
}

# ------------------------------------------------------------------------------
# Main flow
# ------------------------------------------------------------------------------
require_root
export DEBIAN_FRONTEND=noninteractive

sep "Bootstrap Module"
bootstrap_local_modules

sep "Remote Module holen?"
ask_yes_no FETCH_REMOTE "Remote Module (pjsip/extensions/worker/pdf_with_header) neu holen/aktualisieren?" "y"

if [[ "$FETCH_REMOTE" == "y" ]]; then
  sep "Remote Module downloaden"
  download_to "$URL_EXTENSIONS"       "${MOD_CACHE}/extensions.sh"
  download_to "$URL_WORKER"           "${MOD_CACHE}/worker.sh"
  download_to "$URL_PJSIP_1UND1"      "${MOD_CACHE}/pjsip-1und1.sh"
  download_to "$URL_PDF_WITH_HEADER"  "${MOD_CACHE}/pdf_with_header.sh"
  chmod +x "${MOD_CACHE}/extensions.sh" "${MOD_CACHE}/worker.sh" "${MOD_CACHE}/pjsip-1und1.sh" "${MOD_CACHE}/pdf_with_header.sh"
else
  sep "Remote Module: verwende Cache (falls vorhanden)"
  [[ -x "${MOD_CACHE}/extensions.sh" ]]      || die "extensions.sh fehlt im Cache – bitte Remote-Download erlauben."
  [[ -x "${MOD_CACHE}/worker.sh" ]]          || die "worker.sh fehlt im Cache – bitte Remote-Download erlauben."
  [[ -x "${MOD_CACHE}/pjsip-1und1.sh" ]]     || die "pjsip-1und1.sh fehlt im Cache – bitte Remote-Download erlauben."
  [[ -x "${MOD_CACHE}/pdf_with_header.sh" ]] || die "pdf_with_header.sh fehlt im Cache – bitte Remote-Download erlauben."
fi

sep "Module ausführen (feste Reihenfolge, alles gehört dazu)"

run_module "${MOD_DIR}/00-base.sh"
run_module "${MOD_DIR}/10-packages.sh"
run_module "${MOD_DIR}/20-dirs-acl.sh"
run_module "${MOD_DIR}/30-admin-user.sh"
run_module "${MOD_DIR}/40-web-ssl.sh"
run_module "${MOD_DIR}/50-cups-samba.sh"
run_module "${MOD_DIR}/60-asterisk-build.sh"
run_module "${MOD_DIR}/70-rtp-ami.sh"

sep "Remote Provider-PJSIP (1und1) – EINZIGE Stelle für pjsip.conf"
# Export env expected by remote module
# shellcheck disable=SC1090
source /etc/kienzlefax-installer.env
export KFX_PUBLIC_FQDN KFX_SIP_NUMBER KFX_SIP_PASSWORD KFX_FAX_DID KFX_SIP_BIND_PORT
bash -euxo pipefail "${MOD_CACHE}/pjsip-1und1.sh"

sep "Remote Dialplan (extensions.conf)"
bash -euxo pipefail "${MOD_CACHE}/extensions.sh"
asterisk -rx "dialplan reload" || true

sep "Remote Worker + AGI + systemd"
# Pass AMI env + anything else via environment
export KFX_AMI_HOST="127.0.0.1"
export KFX_AMI_PORT="5038"
export KFX_AMI_USER="kfx"
export KFX_AMI_PASS="${KFX_AMI_SECRET}"
bash -euxo pipefail "${MOD_CACHE}/worker.sh"
systemctl daemon-reload || true
systemctl enable --now kienzlefax-worker || true

sep "Remote pdf_with_header.sh"
bash -euxo pipefail "${MOD_CACHE}/pdf_with_header.sh"

sep "Reloads + Status"
asterisk -rx "core reload" || true
asterisk -rx "pjsip reload" || true
asterisk -rx "dialplan reload" || true

systemctl status apache2 --no-pager -l || true
systemctl status cups --no-pager -l || true
systemctl status smbd --no-pager -l || true
systemctl status asterisk --no-pager -l || true
systemctl status kienzlefax-worker --no-pager -l || true

sep "Fertig: Kurzinfo"
echo "Hostname: $(hostname)"
echo "Web: http://$(hostname)/ -> redirect /kienzlefax.php"
echo "Web SSL (self-signed 50y): https://$(hostname)/"
echo "Provider: 1und1 via remote pjsip-1und1.sh (SIP bind port: ${KFX_SIP_BIND_PORT})"
echo "RTP: ${KFX_RTP_START}-${KFX_RTP_END}"
echo "AMI: 127.0.0.1:5038 user=kfx (secret gesetzt)"
echo "CUPS: fax1..fax5 backend=kienzlefaxpdf"
echo "Samba Shares: pdf-zu-fax, sendefehler-*, sendeberichte (admin), fax-eingang (guest)"
echo "Remote module cache: ${MOD_CACHE}"

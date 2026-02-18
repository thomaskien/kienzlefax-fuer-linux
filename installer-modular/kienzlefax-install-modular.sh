#!/usr/bin/env bash
# ==============================================================================
# kienzlefax-install-modular.sh
#
# Version: 3.2.0
# Stand:   2026-02-18
# Autor:   Dr. Thomas Kienzle
#
# Modularer Installer (alles gehört dazu; Provider-spezifisch später).
# - Fragt interaktiv:
#   * Optionen neu setzen? (ENV wiederverwenden möglich)
#   * Hostname setzen (Maschine + Zertifikat CN+SAN)
#   * admin existiert? neu generieren? (Default: N)
#   * Asterisk erkannt? nochmal kompilieren? (Default: N)
#   * Remote-Module JEWEILS EINZELN: holen/aktualisieren? (Default: y wenn fehlt, sonst n)
# - Asterisk immer aus Source (menuselect interaktiv) wenn gewählt/benötigt
# - Fix: INI-Patching via Python (kein awk/mawk Problem)
# - Webroot: kienzlefax.php + index redirect + self-signed SSL 50y
# - Remote Module:
#     extensions.sh, pjsip-1und1.sh, worker.sh, agi.sh, pdf_with_header.sh
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Remote Module URLs
# ------------------------------------------------------------------------------
URL_EXTENSIONS="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/extensions.sh"
URL_PJSIP_1UND1="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pjsip-1und1.sh"
URL_WORKER="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/worker.sh"
URL_AGI="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/agi.sh"
URL_PDF_WITH_HEADER="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pdf_with_header.sh"

# Web bootstrap
WEBROOT="/var/www/html"
WEB_URL_RAW="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax.php"
FAXTON_URL="https://github.com/thomaskien/kienzlefax-fuer-linux/raw/refs/heads/main/faxton.mp3"

# Installer dirs
MOD_BASE="/usr/local/lib/kienzlefax-installer"
MOD_DIR="${MOD_BASE}/modules"
MOD_CACHE="${MOD_BASE}/cache"
STATE_DIR="/var/lib/kienzlefax-installer"
ENVFILE="/etc/kienzlefax-installer.env"

# Defaults
DEFAULT_SIP_BIND_PORT="5070"
DEFAULT_RTP_START="12000"
DEFAULT_RTP_END="12049"
ASTERISK_GIT_REF_DEFAULT="20"

# Asterisk build
ASTERISK_SRC_DIR="/usr/src/asterisk"
ASTERISK_GIT_URL="https://github.com/asterisk/asterisk.git"

# AMI fixed
KFX_AMI_USER="kfx"
KFX_AMI_BINDADDR="127.0.0.1"
KFX_AMI_PORT="5038"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

require_root(){ [[ ${EUID:-0} -eq 0 ]] || die "Bitte als root ausführen."; }

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

download_atomic(){
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  local tmp="${out}.tmp.$$"
  curl -fsSL "$url" -o "$tmp"
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "Download leer/fehlgeschlagen: $url"; }
  mv -f "$tmp" "$out"
}

maybe_fetch_one(){
  # usage: maybe_fetch_one "name" "url" "/path/to/cache.sh"
  local name="$1" url="$2" path="$3"
  local def="n"
  if [[ ! -s "$path" ]]; then def="y"; fi
  local ans
  ask_yes_no ans "Remote holen/aktualisieren: ${name} ?" "$def"
  if [[ "$ans" == "y" ]]; then
    log "[DL ] ${name} <- ${url}"
    download_atomic "$url" "$path"
    chmod +x "$path"
    log "[OK ] ${name} aktualisiert."
  else
    [[ -s "$path" ]] || die "${name} fehlt im Cache, kann nicht übersprungen werden: $path"
    log "[OK ] ${name} unverändert (Cache)."
  fi
}

run_module(){
  local m="$1"
  [[ -x "$m" ]] || die "Modul nicht ausführbar: $m"
  log "[RUN] $m"
  "$m"
  log "[OK ] $m"
}

run_remote_script(){
  # Runs a cached remote script with a helper-function wrapper
  local script="$1"
  [[ -x "$script" ]] || die "Remote script nicht ausführbar: $script"

  (
    set -euo pipefail

    # minimal helpers (exported) for remote scripts that still rely on them
    sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }
    backup_file_ts(){
      local f="$1"
      local stamp=".old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
      if [[ -e "$f" ]]; then
        cp -a "$f" "${f}${stamp}" 2>/dev/null || true
        echo "[INFO] backup: $f -> ${f}${stamp}"
      fi
    }
    ensure_line_in_file(){
      local file="$1" line="$2"
      touch "$file"
      grep -Fxq "$line" "$file" || echo "$line" >>"$file"
    }

    export -f sep backup_file_ts ensure_line_in_file

    if [[ -f "$ENVFILE" ]]; then
      # shellcheck disable=SC1090
      source "$ENVFILE"
    fi

    bash -euo pipefail "$script"
  )
}

# ------------------------------------------------------------------------------
# Local modules
# ------------------------------------------------------------------------------
bootstrap_local_modules(){
  mkdir -p "$MOD_DIR" "$MOD_CACHE" "$STATE_DIR"

  # 00-base: options / hostname / envfile
  cat >"${MOD_DIR}/00-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ask_yes_no(){
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

ask_default(){
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __def="$1"; shift
  local __val=""
  read -r -p "${__prompt} [${__def}]: " __val
  __val="${__val:-$__def}"
  printf -v "$__var" "%s" "$__val"
}

sanitize_digits(){ echo "$1" | tr -cd '0-9'; }

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

backup_file_ts(){
  local f="$1"
  local stamp=".old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}${stamp}" 2>/dev/null || true
    log "backup: $f -> ${f}${stamp}"
  fi
}

ENVFILE="/etc/kienzlefax-installer.env"

DEFAULT_SIP_BIND_PORT="${DEFAULT_SIP_BIND_PORT:-5070}"
DEFAULT_RTP_START="${DEFAULT_RTP_START:-12000}"
DEFAULT_RTP_END="${DEFAULT_RTP_END:-12049}"
ASTERISK_GIT_REF_DEFAULT="${ASTERISK_GIT_REF_DEFAULT:-20}"

sep "Optionen / Hostname / Provider-Daten"

if [[ -f "$ENVFILE" ]]; then
  ask_yes_no RESET_OPTS "Vorhandene Optionen gefunden (${ENVFILE}). Neu setzen?" "n"
else
  RESET_OPTS="y"
fi

if [[ "$RESET_OPTS" == "n" ]]; then
  log "[OK] Verwende vorhandene Optionen aus ${ENVFILE}"
  exit 0
fi

read -r -p "Hostname für diese Maschine (z.B. fax): " KFX_HOSTNAME
[[ -n "${KFX_HOSTNAME}" ]] || die "Hostname darf nicht leer sein."
hostnamectl set-hostname "${KFX_HOSTNAME}"

backup_file_ts /etc/hosts
if grep -qE '^\s*127\.0\.1\.1\s+' /etc/hosts; then
  sed -i -E "s/^\s*127\.0\.1\.1\s+.*/127.0.1.1\t${KFX_HOSTNAME}/" /etc/hosts
else
  echo -e "127.0.1.1\t${KFX_HOSTNAME}" >> /etc/hosts
fi

read -r -p "DynDNS / Public FQDN (z.B. myhost.dyndns.org): " PUBLIC_FQDN
[[ -n "${PUBLIC_FQDN}" ]] || die "PUBLIC_FQDN darf nicht leer sein."

read -r -p "SIP Nummer (gleich Username, nur Ziffern): " SIP_NUMBER_RAW
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

ask_default SIP_BIND_PORT "SIP Bind Port (PJSIP extern; Provider-Config)" "${DEFAULT_SIP_BIND_PORT}"
[[ "$SIP_BIND_PORT" =~ ^[0-9]+$ ]] || die "SIP_BIND_PORT ungültig"

ask_default RTP_START "RTP Start-Port" "${DEFAULT_RTP_START}"
ask_default RTP_END   "RTP End-Port"   "${DEFAULT_RTP_END}"
[[ "$RTP_START" =~ ^[0-9]+$ ]] || die "RTP_START ungültig"
[[ "$RTP_END" =~ ^[0-9]+$ ]] || die "RTP_END ungültig"
[ "$RTP_START" -lt "$RTP_END" ] || die "RTP_START muss < RTP_END sein"

ask_default AST_REF "Asterisk Git-Ref (Branch/Tag/Commit) für Build" "${ASTERISK_GIT_REF_DEFAULT}"

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

# defaults used by dialplan module
KFX_CALLERID_NAME=Fax
EENV
chmod 0600 "$ENVFILE"

log "[OK] Optionen neu gesetzt in ${ENVFILE}"
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

sep "APT: Update/Upgrade + Pakete"
apt-get update
apt-get -y upgrade

apt-get install -y --no-install-recommends \
  ca-certificates curl wget jq \
  acl lsof coreutils iproute2 psmisc \
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

sep "Verzeichnisse + Rechte (kienzlefax)"
mkdir -p "${KZ_BASE}"
for i in 1 2 3 4 5; do mkdir -p "${KZ_BASE}/incoming/fax${i}"; done
mkdir -p "${KZ_BASE}/pdf-zu-fax"
mkdir -p "${KZ_BASE}/sendefehler/eingang" "${KZ_BASE}/sendefehler/berichte"
mkdir -p "${KZ_BASE}/staging" "${KZ_BASE}/queue" "${KZ_BASE}/processing"
mkdir -p "${KZ_BASE}/sendeberichte"
touch "${KZ_BASE}/phonebook.sqlite"

mkdir -p "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}"
chmod 0777 "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}" || true
chmod 0777 "${KZ_BASE}" "${KZ_BASE}"/* || true
chmod 0777 "${KZ_BASE}/sendefehler" "${KZ_BASE}/sendefehler"/* || true

log "[OK] Verzeichnisse/Rechte erstellt."
EOF
  chmod +x "${MOD_DIR}/20-dirs-acl.sh"

  # 30-admin-user
  cat >"${MOD_DIR}/30-admin-user.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ask_yes_no(){
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

sep "Admin-Account anlegen + sudo + Samba"
if id admin >/dev/null 2>&1; then
  ask_yes_no REGEN "User 'admin' existiert bereits. Neu generieren (inkl. Passwort neu setzen)?" "n"
  if [[ "$REGEN" == "n" ]]; then
    log "[OK] admin unverändert gelassen."
    exit 0
  fi
  log "[INFO] admin bleibt bestehen; Passwörter werden neu gesetzt."
else
  useradd -m -s /bin/bash admin
  log "[OK] User 'admin' angelegt."
fi

usermod -aG sudo admin || true

echo
echo "==== Linux-Login-Passwort für 'admin' setzen (2× Eingabe) ===="
passwd admin

echo
echo "==== Samba-Passwort für 'admin' setzen (2× Eingabe) ===="
smbpasswd -a admin || true
smbpasswd -e admin || true

log "[OK] admin: sudo+Samba gesetzt."
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

sep "Webroot bootstrappen (kienzlefax.php + faxton.mp3) + index redirect"
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

sep "Apache SSL: self-signed 50 Jahre (CN+SAN=Hostname) + aktivieren"
CERT_DIR="/etc/ssl/kienzlefax"
CERT_KEY="${CERT_DIR}/kienzlefax.key"
CERT_CRT="${CERT_DIR}/kienzlefax.crt"
mkdir -p "$CERT_DIR"
chmod 0700 "$CERT_DIR"

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

a2enmod ssl >/dev/null 2>&1 || true

SSL_SITE="/etc/apache2/sites-available/default-ssl.conf"
[[ -f "$SSL_SITE" ]] && cp -a "$SSL_SITE" "${SSL_SITE}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" || true

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
  sed -i -E "s|^\s*SSLCertificateFile\s+.*|SSLCertificateFile      ${CERT_CRT}|" "$SSL_SITE" || true
  sed -i -E "s|^\s*SSLCertificateKeyFile\s+.*|SSLCertificateKeyFile   ${CERT_KEY}|" "$SSL_SITE" || true
  if ! grep -qE '^\s*ServerName\s+' "$SSL_SITE"; then
    sed -i -E "s|<VirtualHost[^>]*>|&\n    ServerName ${KFX_HOSTNAME}|" "$SSL_SITE" || true
  fi
fi

a2ensite default-ssl >/dev/null 2>&1 || true
systemctl enable --now apache2
systemctl restart apache2

log "[OK] Web+SSL: https://${KFX_HOSTNAME}/"
EOF
  chmod +x "${MOD_DIR}/40-web-ssl.sh"

  # 50-cups-samba (gleich wie vorher; bewusst "alles gehört dazu")
  cat >"${MOD_DIR}/50-cups-samba.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

KZ_BASE="/srv/kienzlefax"
SPOOL_PDF_DIR="/var/spool/asterisk/fax"

sep "CUPS Backend + fax1..fax5 + Samba Shares"

if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "cups-browsed.service"; then
  systemctl stop cups-browsed || true
  systemctl disable cups-browsed || true
fi

BACKEND="/usr/lib/cups/backend/kienzlefaxpdf"
BACKEND_LOG="/var/log/kienzlefaxpdf-backend.log"

cat > "$BACKEND" <<'BACKEND_EOF'
#!/bin/bash
set -u
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
if [[ -d "$CUPSTMP" && -w "$CUPSTMP" ]]; then TMPBASE="$CUPSTMP"; fi
log() { echo "[$($DATE -Is)] $*" >> "$LOG"; }

if [[ $# -eq 0 ]]; then
  for i in 1 2 3 4 5; do
    echo "direct kienzlefaxpdf \"KienzleFax PDF Drop\" \"kienzlefaxpdf:/fax$i\""
  done
  exit 0
fi

JOBID="${1:-}"
USER="${2:-unknown}"
TITLE="${3:-job}"
FILE="${6:-}"
URI="${DEVICE_URI:-}"
PRN="${URI#kienzlefaxpdf:/}"
PRN="${PRN%%/*}"
log "START jobid=$JOBID user=$USER title=$TITLE file='${FILE:-}' uri='$URI' prn='$PRN' tmpbase='$TMPBASE'"
[[ -n "$JOBID" ]] || { log "ERROR: missing jobid"; exit 1; }
[[ "$PRN" =~ ^fax[1-5]$ ]] || { log "ERROR: invalid prn '$PRN'"; exit 1; }

OUTDIR="$DESTBASE/$PRN"
$MKDIR -p "$OUTDIR" || { log "ERROR: mkdir '$OUTDIR' failed"; exit 1; }

ts="$($DATE +%Y%m%d-%H%M%S)"
base="$(echo "$TITLE" | $TR -c 'A-Za-z0-9._-' '_' | $SED 's/^_//;s/_$//')"
base="${base:-print}"
out="$OUTDIR/${ts}__${PRN}__${USER}__${base}__${JOBID}.pdf"

tmp_in=""
if [[ -n "${FILE:-}" && -f "$FILE" ]]; then
  infile="$FILE"
else
  tmp_in="$($MKTEMP --tmpdir="$TMPBASE" "kienzlefaxpdf.${JOBID}.XXXXXX" 2>/dev/null)"
  [[ -n "$tmp_in" ]] || { log "ERROR: mktemp stdin failed"; exit 1; }
  cat > "$tmp_in"
  infile="$tmp_in"
fi

tmp_pdf="$($MKTEMP --tmpdir="$TMPBASE" "kienzlefaxpdf.${JOBID}.XXXXXX.pdf" 2>/dev/null)"
[[ -n "$tmp_pdf" ]] || { log "ERROR: mktemp pdf failed"; [[ -n "$tmp_in" ]] && rm -f "$tmp_in"; exit 1; }

export TMPDIR="$TMPBASE"
if ! $TIMEOUT 60s $GS -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="$tmp_pdf" "$infile" >>"$LOG" 2>&1; then
  rc=$?
  log "ERROR: gs failed rc=$rc"
  rm -f "$tmp_pdf"
  [[ -n "$tmp_in" ]] && rm -f "$tmp_in"
  exit 1
fi

$MV -f "$tmp_pdf" "$out" || { log "ERROR: mv failed"; rm -f "$tmp_pdf"; [[ -n "$tmp_in" ]] && rm -f "$tmp_in"; exit 1; }
$CHMOD 0664 "$out" || true
[[ -n "$tmp_in" ]] && rm -f "$tmp_in" || true
log "OK wrote '$out'"
exit 0
BACKEND_EOF

chmod 0755 "$BACKEND"
chown root:root "$BACKEND"

touch "$BACKEND_LOG"
chown lp:lp "$BACKEND_LOG" || true
chmod 0664 "$BACKEND_LOG"

systemctl enable --now cups || true
systemctl restart cups || true

for i in 1 2 3 4 5; do lpadmin -x "fax$i" 2>/dev/null || true; done
for i in 1 2 3 4 5; do
  PRN="fax$i"
  lpadmin -p "$PRN" -E -v "kienzlefaxpdf:/$PRN" -m raw
  lpadmin -p "$PRN" -o printer-is-shared=true
  lpadmin -p "$PRN" -o media=A4
  cupsenable "$PRN"
  cupsaccept "$PRN"
done

mkdir -p "$SPOOL_PDF_DIR"
chmod 0777 "$SPOOL_PDF_DIR" || true

cat > /etc/samba/smb.conf <<EOFSMB
[global]
   workgroup = WORKGROUP
   server string = kienzlefax samba
   security = user
   map to guest = Bad User
   guest account = nobody
   server min protocol = SMB2
   smb ports = 445
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

[pdf-zu-fax]
   path = /srv/kienzlefax/pdf-zu-fax
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0666
   directory mask = 2777

[sendefehler-eingang]
   path = /srv/kienzlefax/sendefehler/eingang
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0666
   directory mask = 2777

[sendefehler-berichte]
   path = /srv/kienzlefax/sendefehler/berichte
   browseable = yes
   read only = yes
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0444
   directory mask = 2777

[sendeberichte]
   path = /srv/kienzlefax/sendeberichte
   browseable = yes
   read only = yes
   guest ok = no
   valid users = admin
   force group = kienzlefax
   create mask = 0640
   directory mask = 2750

[fax-eingang]
   path = /var/spool/asterisk/fax
   browseable = yes
   writable = yes
   read only = no
   guest ok = yes
   public = yes
   create mask = 0777
   directory mask = 0777
   force user = nobody
   force group = nogroup
EOFSMB

systemctl enable --now smbd nmbd || true
systemctl restart smbd nmbd || true

log "[OK] CUPS+Samba bereit."
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

  # 70-rtp-ami (Python patcher)
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

ini_set_kv_py(){
  local file="$1" section="$2" key="$3" value="$4"
  python3 - "$file" "$section" "$key" "$value" <<'PY'
import sys, re, pathlib
file, section, key, value = sys.argv[1:5]
path = pathlib.Path(file)
text = path.read_text(encoding="utf-8") if path.exists() else ""
lines = text.splitlines()
sec_re = re.compile(r'^\s*\[' + re.escape(section) + r'\]\s*$')
any_sec_re = re.compile(r'^\s*\[[^\]]+\]\s*$')
key_re = re.compile(r'^\s*' + re.escape(key) + r'\s*=')
out=[]
i=0
found=False
while i < len(lines):
    line = lines[i]
    if sec_re.match(line):
        found=True
        out.append(line); i += 1
        wrote=False
        while i < len(lines) and not any_sec_re.match(lines[i]):
            if key_re.match(lines[i]) and not wrote:
                out.append(f"{key} = {value}"); wrote=True; i += 1; continue
            out.append(lines[i]); i += 1
        if not wrote:
            out.append(f"{key} = {value}")
        continue
    out.append(line); i += 1
if not found:
    if out and out[-1].strip() != "":
        out.append("")
    out.append(f"[{section}]")
    out.append(f"{key} = {value}")
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

ensure_line_in_file(){
  local file="$1" line="$2"
  touch "$file"
  grep -Fxq "$line" "$file" || echo "$line" >>"$file"
}

sep "Asterisk: RTP Range setzen"
[[ -f "$RTP_CONF" ]] && cp -a "$RTP_CONF" "${RTP_CONF}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" || true
touch "$RTP_CONF"
ini_set_kv_py "$RTP_CONF" "general" "rtpstart" "$KFX_RTP_START"
ini_set_kv_py "$RTP_CONF" "general" "rtpend"   "$KFX_RTP_END"

sep "Asterisk AMI/Manager aktivieren + nur localhost"
[[ -f "$MANAGER_CONF" ]] && cp -a "$MANAGER_CONF" "${MANAGER_CONF}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" || true
touch "$MANAGER_CONF"

ensure_line_in_file "$MANAGER_CONF" '#include "/etc/asterisk/manager.d/*.conf"'
mkdir -p /etc/asterisk/manager.d

ini_set_kv_py "$MANAGER_CONF" "general" "enabled"    "yes"
ini_set_kv_py "$MANAGER_CONF" "general" "webenabled" "no"
ini_set_kv_py "$MANAGER_CONF" "general" "bindaddr"   "127.0.0.1"
ini_set_kv_py "$MANAGER_CONF" "general" "port"       "5038"

cat >/etc/asterisk/manager.d/kfx.conf <<EOFCONF
[kfx]
secret = ${KFX_AMI_SECRET}
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
# Main
# ------------------------------------------------------------------------------
require_root
export DEBIAN_FRONTEND=noninteractive

sep "Bootstrap lokale Module"
bootstrap_local_modules

sep "Remote Module einzeln holen/aktualisieren"
maybe_fetch_one "extensions.sh"      "$URL_EXTENSIONS"      "${MOD_CACHE}/extensions.sh"
maybe_fetch_one "pjsip-1und1.sh"     "$URL_PJSIP_1UND1"     "${MOD_CACHE}/pjsip-1und1.sh"
maybe_fetch_one "worker.sh"          "$URL_WORKER"          "${MOD_CACHE}/worker.sh"
maybe_fetch_one "agi.sh"             "$URL_AGI"             "${MOD_CACHE}/agi.sh"
maybe_fetch_one "pdf_with_header.sh" "$URL_PDF_WITH_HEADER" "${MOD_CACHE}/pdf_with_header.sh"

sep "Module ausführen (feste Reihenfolge)"
run_module "${MOD_DIR}/00-base.sh"
run_module "${MOD_DIR}/10-packages.sh"
run_module "${MOD_DIR}/20-dirs-acl.sh"
run_module "${MOD_DIR}/30-admin-user.sh"
run_module "${MOD_DIR}/40-web-ssl.sh"
run_module "${MOD_DIR}/50-cups-samba.sh"

# Asterisk build decision
ASTERISK_DETECTED="n"
command -v asterisk >/dev/null 2>&1 && ASTERISK_DETECTED="y"
if [[ "$ASTERISK_DETECTED" == "y" ]]; then
  ask_yes_no DO_ASTERISK_BUILD "Asterisk ist bereits installiert. Nochmal aus Source kompilieren?" "n"
else
  DO_ASTERISK_BUILD="y"
fi

if [[ "$DO_ASTERISK_BUILD" == "y" ]]; then
  run_module "${MOD_DIR}/60-asterisk-build.sh"
else
  sep "Asterisk Build übersprungen (bestehende Installation wird genutzt)"
  systemctl enable --now asterisk || true
fi

run_module "${MOD_DIR}/70-rtp-ami.sh"

# Load ENV
# shellcheck disable=SC1090
source "$ENVFILE"

# ------------------------------------------------------------------------------
# Export variables for remote scripts (compatibility layer)
# ------------------------------------------------------------------------------
export KFX_HOSTNAME KFX_PUBLIC_FQDN KFX_SIP_NUMBER KFX_SIP_PASSWORD KFX_FAX_DID KFX_SIP_BIND_PORT
export KFX_RTP_START KFX_RTP_END KFX_AST_REF KFX_AMI_SECRET

# Common legacy names (remote scripts may still use these)
export PJSIP_USER="${PJSIP_USER:-$KFX_SIP_NUMBER}"
export PJSIP_PASS="${PJSIP_PASS:-$KFX_SIP_PASSWORD}"
export SIP_BIND_PORT="${SIP_BIND_PORT:-$KFX_SIP_BIND_PORT}"
export SIP_PORT="${SIP_PORT:-$KFX_SIP_BIND_PORT}"
export FAX_DID="${FAX_DID:-$KFX_FAX_DID}"
export PUBLIC_FQDN="${PUBLIC_FQDN:-$KFX_PUBLIC_FQDN}"

# AMI env for worker scripts
export KFX_AMI_HOST="127.0.0.1"
export KFX_AMI_PORT="5038"
export KFX_AMI_USER="kfx"
export KFX_AMI_PASS="${KFX_AMI_SECRET}"

export AMI_HOST="${AMI_HOST:-$KFX_AMI_HOST}"
export AMI_PORT="${AMI_PORT:-$KFX_AMI_PORT}"
export AMI_USER="${AMI_USER:-$KFX_AMI_USER}"
export AMI_SECRET="${AMI_SECRET:-$KFX_AMI_PASS}"

# ------------------------------------------------------------------------------
# Remote scripts execution
# ------------------------------------------------------------------------------
sep "Remote Provider-PJSIP (befüllt pjsip.conf)"
run_remote_script "${MOD_CACHE}/pjsip-1und1.sh"
asterisk -rx "pjsip reload" || true

sep "Remote Dialplan (befüllt extensions.conf)"
run_remote_script "${MOD_CACHE}/extensions.sh"
asterisk -rx "dialplan reload" || true

sep "Remote AGI installieren"
run_remote_script "${MOD_CACHE}/agi.sh"

sep "Remote Worker installieren"
run_remote_script "${MOD_CACHE}/worker.sh"
systemctl daemon-reload || true
systemctl enable --now kienzlefax-worker || true

sep "Remote pdf_with_header.sh installieren"
run_remote_script "${MOD_CACHE}/pdf_with_header.sh"

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
echo "Web: http://$(hostname)/ -> /kienzlefax.php"
echo "Web SSL (self-signed 50y): https://$(hostname)/"
echo "SIP Bind Port (Provider): ${KFX_SIP_BIND_PORT}"
echo "RTP: ${KFX_RTP_START}-${KFX_RTP_END}"
echo "AMI: 127.0.0.1:5038 user=kfx (secret gesetzt)"
echo "Remote module cache: ${MOD_CACHE}"

#!/usr/bin/env bash
# ==============================================================================
# kienzlefax-install-modular.sh
#
# Version: 3.3.8
# Stand:   2026-06-23
# Autor:   Dr. Thomas Kienzle
#
# Modularer Installer (alles gehört dazu; Provider per Template-Auswahl).
# - Fragt interaktiv:
#   * Optionen neu setzen? (ENV wiederverwenden möglich)
#   * Hostname setzen (Maschine + Zertifikat CN+SAN)
#   * Praxis-Kopfzeile fuer gesendete PDFs/Faxe
#   * Admin-Passwort fuer Linux und Samba
#   * optional: bisherigen Erstbenutzer entfernen
#   * optional: Asterisk-menuselect manuell pruefen (Default: N)
#   * optional: Installationsbericht mit Klartext-Passwoertern erzeugen (Default: Y)
# - Asterisk baut nichtinteraktiv; menuselect ist nur noch optionale manuelle Pruefung
# - Fix: INI-Patching via Python (kein awk/mawk Problem)
# - Webroot: kienzlefax.php + index redirect + self-signed SSL 50y
# - Remote Module:
#     extensions.sh, pjsip-provider.sh, worker.sh, agi.sh, pdf_with_header.sh, scan_ocr.sh
#
# NEU in 3.2.1 (konservativ):
# - /etc/default/kienzlefax-worker wird angelegt (KFX_AMI_PASS NICHT interaktiv; kommt aus ENV/Default).
# - systemd Unit exakt wie gewünscht: /etc/systemd/system/kienzlefax-worker.service (EnvironmentFile=...).
# - kienzlefax.php wird optional neu geladen (Abfrage).
#
# NEU in 3.2.2 (konservativ):
# - Nach Asterisk-Start wird auf die CLI/den Control-Socket gewartet, bevor AMI/PJSIP/Dialplan-Reloads laufen.
#
# NEU in 3.2.3 (konservativ):
# - CUPS-Freigabe fuer Bonjour/DNS-SD wird global aktiviert und Avahi explizit gestartet.
# - CUPS bleibt fuer Bonjour-Anzeigen aktiv (IdleExitTimeout=0).
#
# NEU in 3.2.4 (konservativ):
# - incoming/fax1..fax5 werden explizit fuer den CUPS-Backend schreibbar gemacht.
# - CUPS-Queues nutzen wieder generic.ppd, falls vorhanden; raw bleibt nur Fallback.
# - Vom CUPS-Backend erzeugte PDFs werden fuer die Web-UI lesbar abgelegt.
#
# NEU in 3.2.5 (konservativ):
# - CUPS-Backend erzwingt A4-PDF-Ausgabe; Queues setzen media und PageSize auf A4.
#
# NEU in 3.2.6 (konservativ):
# - Praxis-Kopfzeile fuer pdf_with_header.sh wird im Installer abgefragt und an den Worker durchgereicht.
#
# NEU in 3.2.7 (konservativ):
# - Scan-OCR Pipeline mit Eingangs- und Ergebnis-Share.
# - Empfangene Fax-PDFs werden zusaetzlich in die OCR-Pipeline kopiert.
#
# NEU in 3.2.8 (konservativ):
# - Empfangene Faxe erscheinen erst nach OCR/Fallback im bestehenden Share fax-eingang.
# - Zweiter Watcher scan-ocr-fax.service verarbeitet /srv/scan/fax-eingang -> /var/spool/asterisk/fax.
#
# NEU in 3.2.9 (konservativ):
# - Provider-/SIP-Passwort wird shell-sicher in /etc/kienzlefax-installer.env geschrieben.
#   Dadurch bleiben Sonderzeichen erhalten und PJSIP-Registrationen laufen nicht mit verfälschtem Passwort.
#
# NEU in 3.2.10 (konservativ):
# - Provider-PJSIP-Modul stoesst die Registrierung aktiv an, wartet auf Registered
#   und startet Asterisk einmal neu, falls die Registrierung im laufenden Zustand auf Rejected/Unregistered klebt.
#
# NEU in 3.2.11 (konservativ):
# - Asterisk-Build schreibt eine native systemd-Unit und laesst `make config` nur noch mit Timeout laufen,
#   damit `systemd-sysv-install enable asterisk` den Installer auf frischen Systemen nicht blockiert.
#
# NEU in 3.2.12 (konservativ):
# - Auch beim Ueberspringen des Asterisk-Builds wird die native Asterisk-systemd-Unit sichergestellt,
#   bevor Asterisk gestartet/aktiviert wird.
#
# NEU in 3.2.13 (konservativ):
# - Asterisk-Build nutzt auf Raspberry Pi standardmaessig maximal 2 parallele Jobs und faellt bei
#   pjproject/Compiler-Fehlern automatisch auf `make -j1` zurueck.
#
# NEU in 3.3.0:
# - Installer-Dialoge werden an den Anfang gezogen; der lange Installationslauf bleibt ohne weitere Rueckfragen.
# - Admin-Passwort wird initial gesetzt und fuer Linux-User `admin` sowie Samba-User `admin` verwendet.
# - Optional kann der bisherige Erstbenutzer nach Admin-Anlage entfernt werden; `admin` behaelt sudo mit Passwort.
# - DynDNS/Public FQDN ist optional, aber zur optimalen Stabilitaet unbedingt empfohlen.
# - Asterisk-menuselect wird standardmaessig nicht geoeffnet; benoetigte Fax-Module werden nichtinteraktiv aktiviert.
# - Installationsbericht mit SIP-/Admin-Passwort, aktueller IP, Portweiterleitungen, Config-Dateien und Share-Uebersicht.
# - Ausgehende Fax-Kopfzeile reserviert ein Headerband und verkleinert den Seiteninhalt minimal.
# - OCR-Eingangsshare heisst `hierhin-scannen-fuer-ocr` statt `scan-to-ocr`.
#
# NEU in 3.3.1:
# - Asterisk-menuselect behandelt versionsabhaengig fehlende Optionen `app_fax` und `format_tiff`
#   als optional; Pflicht fuer Fax bleibt `res_fax` und `res_fax_spandsp`.
#
# NEU in 3.3.2:
# - Laufoptionen werden bei jedem Installerstart neu abgefragt, auch wenn die Grundkonfiguration
#   wiederverwendet wird: Remote-Module, Web-Update, Asterisk-Rebuild, Bericht, Benutzerentfernung.
# - Installationsbericht warnt klar: Web-Ports 80/443 niemals ins Internet weiterleiten.
#
# NEU in 3.3.3:
# - Ausgehende Fax-Kopfzeile nutzt ein schmaleres Headerband und kleinere Schrift,
#   damit weitergeleitete Faxe deutlich weniger verkleinert werden.
#
# NEU in 3.3.4:
# - Samba-Share `sendeberichte` verzichtet auf eine nicht angelegte Force-Gruppe,
#   damit der Admin-Zugriff nicht an einer fehlenden lokalen Gruppe scheitert.
#
# NEU in 3.3.5:
# - Admin-User uebernimmt vorhandene SSH-authorized_keys des bisherigen Installationsusers,
#   damit Public-Key-only-SSH den Admin-Zugang nicht blockiert.
# - Wenn der optionale alte User wegen laufender Prozesse nicht geloescht werden kann,
#   wird sein Login gesperrt und sein SSH-Key deaktiviert.
#
# NEU in 3.3.6:
# - Admin-Passwort kann am Anfang wahlweise manuell gesetzt oder sicher generiert werden.
#
# NEU in 3.3.7:
# - Globale Begrenzung auf drei logische Faxverbindungen via Dialplan-Kapazitaetsguard.
# - Asterisk-Module func_groupcount.so und func_lock.so werden in modules.conf dauerhaft geladen
#   und vor dem Remote-Dialplan-Reload geprueft.
#
# NEU in 3.3.8:
# - Anzahl Faxdrucker wird abgefragt (1-100, Default 5) und CUPS/Backend/sources.json folgen dynamisch.
# - PDF-zu-Fax-Eingaenge werden abgefragt; Default bleibt ein unnummerierter Share `pdf-zu-fax`.
# - Provider-Auswahl am Anfang: 1und1, Telekom, sipgate oder manuell; Provider-Template schreibt pjsip.conf.
# - sources.json wird unter /srv/kienzlefax/config/sources.json erzeugt.
# - SSH authorized_keys werden neben admin auch nach /root/.ssh/authorized_keys uebernommen.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Remote Module URLs
# ------------------------------------------------------------------------------
URL_EXTENSIONS="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/extensions.sh"
URL_PJSIP_PROVIDER="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pjsip-provider.sh"
URL_WORKER="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/worker.sh"
URL_AGI="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/agi.sh"
URL_PDF_WITH_HEADER="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/pdf_with_header.sh"
URL_SCAN_OCR="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/scan_ocr.sh"

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

# AMI local defaults (NICHT interaktiv; konfigurierbar über ENVFILE/Installer)
DEFAULT_AMI_SECRET="mysecret"

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
  local ans="${KFX_REMOTE_REFRESH:-y}"
  if [[ ! -s "$path" ]]; then ans="y"; fi
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

wait_for_asterisk_cli(){
  local timeout="${1:-60}"
  local waited=0
  command -v asterisk >/dev/null 2>&1 || return 1
  while (( waited < timeout )); do
    if asterisk -rx "core show version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

require_asterisk_cli(){
  local timeout="${1:-60}"
  log "[WAIT] Warte auf Asterisk CLI/Control-Socket (max ${timeout}s)..."
  wait_for_asterisk_cli "$timeout" || die "Asterisk CLI ist nach ${timeout}s nicht bereit."
  log "[OK ] Asterisk CLI bereit."
}

asterisk_rx(){
  local cmd="$1"
  if wait_for_asterisk_cli 30; then
    asterisk -rx "$cmd" || true
  else
    log "[WARN] Asterisk CLI nicht bereit; überspringe: ${cmd}"
  fi
}

install_native_asterisk_unit(){
  cat >/etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
ExecReload=/usr/sbin/asterisk -rx "core reload"
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 /etc/systemd/system/asterisk.service
  systemctl daemon-reload
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

ask_int_range(){
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __def="$1"; shift
  local __min="$1"; shift
  local __max="$1"; shift
  local __val=""
  while true; do
    read -r -p "${__prompt} [${__def}]: " __val
    __val="${__val:-$__def}"
    if [[ "$__val" =~ ^[0-9]+$ ]] && (( __val >= __min && __val <= __max )); then
      printf -v "$__var" "%s" "$__val"
      return 0
    fi
    echo "Bitte eine Zahl von ${__min} bis ${__max} eingeben."
  done
}

read_secret_twice(){
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __a="" __b=""
  while true; do
    read -r -s -p "${__prompt}: " __a
    echo
    read -r -s -p "${__prompt} wiederholen: " __b
    echo
    if [[ -z "$__a" ]]; then
      echo "Passwort darf nicht leer sein."
      continue
    fi
    if [[ "$__a" != "$__b" ]]; then
      echo "Passwoerter stimmen nicht ueberein."
      continue
    fi
    printf -v "$__var" "%s" "$__a"
    return 0
  done
}

generate_secure_password(){
  local pw=""
  if command -v python3 >/dev/null 2>&1; then
    pw="$(python3 - <<'PY'
import secrets
alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
print("".join(secrets.choice(alphabet) for _ in range(28)))
PY
)"
  fi

  if [[ ${#pw} -lt 24 ]] && command -v openssl >/dev/null 2>&1; then
    pw="$(openssl rand -base64 64 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 28 || true)"
  fi

  [[ ${#pw} -ge 24 ]] || die "Konnte kein sicheres Admin-Passwort generieren."
  printf '%s' "$pw"
}

sanitize_digits(){ echo "$1" | tr -cd '0-9'; }

normalize_provider(){
  local p
  p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  case "$p" in
    1|1und1|und1|ionos) echo "1und1";;
    2|telekom|deutschetelekom|tkom|t-online|tonline) echo "telekom";;
    3|sipgate) echo "sipgate";;
    4|manual|manuell|manuellkonfiguration) echo "manual";;
    *) echo "";;
  esac
}

provider_label(){
  case "${1:-}" in
    1und1) echo "1&1 Deutschland";;
    telekom) echo "Deutsche Telekom";;
    sipgate) echo "sipgate";;
    manual) echo "Manuelle Konfiguration";;
    *) echo "${1:-unbekannt}";;
  esac
}

detect_current_user_candidate(){
  local cand=""
  cand="${SUDO_USER:-}"
  if [[ -z "$cand" || "$cand" == "root" || "$cand" == "admin" ]]; then
    cand="$(logname 2>/dev/null || true)"
  fi
  if [[ -z "$cand" || "$cand" == "root" || "$cand" == "admin" ]]; then
    cand="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "admin" && $1 != "nobody" {print $1; exit}')"
  fi
  if [[ -n "$cand" && "$cand" != "root" && "$cand" != "admin" ]] && id "$cand" >/dev/null 2>&1; then
    printf '%s\n' "$cand"
  fi
}

quote_env_value(){
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$/\\$}"
  s="${s//\`/\\\`}"
  printf '"%s"' "$s"
}

upsert_env_line(){
  local key="$1" value="$2" file="${3:-$ENVFILE}"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

collect_run_options(){
  ask_yes_no REMOTE_REFRESH "Remote-Module aus GitHub holen/aktualisieren?" "y"
  ask_yes_no WEB_REFRESH "Weboberflaeche neu herunterladen/aktualisieren?" "y"
  ask_yes_no AST_MANUAL_MENUSELECT "Asterisk-Modulauswahl manuell zur Pruefung oeffnen? Beenden mit X" "n"

  if command -v asterisk >/dev/null 2>&1; then
    ask_yes_no AST_REBUILD "Asterisk ist bereits installiert. Nochmal aus Source kompilieren?" "n"
  else
    AST_REBUILD="y"
    log "[INFO] Asterisk ist noch nicht installiert; Build wird ausgefuehrt."
  fi

  ask_yes_no INSTALL_REPORT "Installationsbericht mit Klartext-Passwoertern erzeugen?" "y"

  REMOVE_USER_NAME=""
  REMOVE_USER_HOME="n"
  CURRENT_USER_CANDIDATE="$(detect_current_user_candidate || true)"
  if [[ -n "$CURRENT_USER_CANDIDATE" ]]; then
    ask_yes_no REMOVE_CURRENT_USER "Aktuellen Benutzer '${CURRENT_USER_CANDIDATE}' am Ende entfernen?" "n"
    if [[ "$REMOVE_CURRENT_USER" == "y" ]]; then
      REMOVE_USER_NAME="$CURRENT_USER_CANDIDATE"
      ask_yes_no REMOVE_USER_HOME "Home-Verzeichnis von '${CURRENT_USER_CANDIDATE}' ebenfalls loeschen?" "n"
    fi
  fi
}

write_run_options_to_env(){
  local remove_user_name_env
  remove_user_name_env="$(quote_env_value "${REMOVE_USER_NAME:-}")"
  upsert_env_line KFX_REMOTE_REFRESH "${REMOTE_REFRESH:-y}"
  upsert_env_line KFX_WEB_REFRESH "${WEB_REFRESH:-y}"
  upsert_env_line KFX_ASTERISK_MANUAL_MENUSELECT "${AST_MANUAL_MENUSELECT:-n}"
  upsert_env_line KFX_REBUILD_ASTERISK "${AST_REBUILD:-y}"
  upsert_env_line KFX_INSTALL_REPORT_WITH_PASSWORDS "${INSTALL_REPORT:-y}"
  upsert_env_line KFX_REMOVE_USER_NAME "${remove_user_name_env}"
  upsert_env_line KFX_REMOVE_USER_HOME "${REMOVE_USER_HOME:-n}"
  chmod 0600 "$ENVFILE"
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
DEFAULT_AMI_SECRET="${DEFAULT_AMI_SECRET:-mysecret}"

sep "Optionen / Hostname / Provider-Daten"

if [[ -f "$ENVFILE" ]]; then
  ask_yes_no RESET_OPTS "Vorhandene Optionen gefunden (${ENVFILE}). Neu setzen?" "n"
else
  RESET_OPTS="y"
fi

if [[ "$RESET_OPTS" == "n" ]]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
  if [[ -z "${KFX_ADMIN_PASSWORD:-}" || -z "${KFX_PROVIDER:-}" || -z "${KFX_SIP_USER:-}" || -z "${KFX_FAX_PRINTER_COUNT:-}" || -z "${KFX_PDF_INPUT_COUNT:-}" ]]; then
    log "[INFO] Vorhandene Optionen sind aelter als 3.3.8; Eingaben werden neu gesammelt."
    RESET_OPTS="y"
  else
    log "[OK] Verwende vorhandene Grundkonfiguration aus ${ENVFILE}"
    sep "Laufoptionen fuer diese Installation"
    collect_run_options
    write_run_options_to_env
    log "[OK] Laufoptionen aktualisiert in ${ENVFILE}"
    exit 0
  fi
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

echo
echo "Provider-Auswahl:"
echo "  1 = 1&1 Deutschland (bisher getesteter Standard)"
echo "  2 = Deutsche Telekom (Template; Felder bitte pruefen)"
echo "  3 = sipgate (Template; Felder bitte pruefen)"
echo "  4 = manuell (pjsip.conf wird nicht automatisch geschrieben)"
while true; do
  ask_default PROVIDER_IN "Provider" "1und1"
  KFX_PROVIDER="$(normalize_provider "$PROVIDER_IN")"
  if [[ -n "$KFX_PROVIDER" ]]; then
    break
  fi
  echo "Bitte 1und1, telekom, sipgate oder manuell eingeben."
done
KFX_PROVIDER_LABEL="$(provider_label "$KFX_PROVIDER")"
echo "[OK] Provider: ${KFX_PROVIDER_LABEL}"

echo "DynDNS / Public FQDN ist optional, zur optimalen Stabilitaet aber unbedingt empfohlen."
read -r -p "DynDNS / Public FQDN (Enter = leer lassen): " PUBLIC_FQDN

echo
echo "==== SIP Zugangsdaten ===="
while true; do
  ask_default SIP_USER "SIP Benutzername/Auth-ID" ""
  [[ -n "$SIP_USER" ]] && break
  echo "SIP Benutzername/Auth-ID darf nicht leer sein."
done

while true; do
  read -r -p "SIP Rufnummer / CallerID (nur Ziffern; Enter = SIP Benutzername falls nur Ziffern): " SIP_NUMBER_RAW
  if [[ -z "$SIP_NUMBER_RAW" ]]; then
    SIP_NUMBER_RAW="$SIP_USER"
  fi
  SIP_NUMBER="$(sanitize_digits "${SIP_NUMBER_RAW}")"
  if [[ -n "$SIP_NUMBER" ]]; then
    break
  fi
  echo "Bitte eine Rufnummer/CallerID mit Ziffern eingeben."
done
unset SIP_NUMBER_RAW

echo
echo "==== SIP Passwort eingeben (sichtbar aus = nein) ===="
read_secret_twice SIP_PASSWORD "SIP Passwort"

case "$KFX_PROVIDER" in
  1und1)
    PROVIDER_DOMAIN_DEFAULT="sip.1und1.de"
    PROVIDER_IDENTIFY_DEFAULT="212.227.0.0/16"
    PROVIDER_EXPIRATION_DEFAULT="300"
    ;;
  telekom)
    PROVIDER_DOMAIN_DEFAULT="tel.t-online.de"
    PROVIDER_IDENTIFY_DEFAULT=""
    PROVIDER_EXPIRATION_DEFAULT="300"
    ;;
  sipgate)
    PROVIDER_DOMAIN_DEFAULT="sipgate.de"
    PROVIDER_IDENTIFY_DEFAULT=""
    PROVIDER_EXPIRATION_DEFAULT="600"
    ;;
  manual)
    PROVIDER_DOMAIN_DEFAULT=""
    PROVIDER_IDENTIFY_DEFAULT=""
    PROVIDER_EXPIRATION_DEFAULT="300"
    ;;
esac

if [[ "$KFX_PROVIDER" != "manual" ]]; then
  ask_default KFX_SIP_DOMAIN "SIP Registrar/Domain fuer ${KFX_PROVIDER_LABEL}" "$PROVIDER_DOMAIN_DEFAULT"
  [[ -n "$KFX_SIP_DOMAIN" ]] || die "SIP Registrar/Domain darf nicht leer sein."
  ask_default KFX_SIP_OUTBOUND_PROXY "SIP Outbound Proxy (Enter = keiner)" ""
  ask_default KFX_SIP_IDENTIFY_MATCH "PJSIP identify match (IP/Netz; Enter = keiner)" "$PROVIDER_IDENTIFY_DEFAULT"
  ask_default KFX_SIP_EXPIRATION "SIP Registration Expiration Sekunden" "$PROVIDER_EXPIRATION_DEFAULT"
  [[ "$KFX_SIP_EXPIRATION" =~ ^[0-9]+$ ]] || die "SIP Registration Expiration ungueltig."
else
  KFX_SIP_DOMAIN=""
  KFX_SIP_OUTBOUND_PROXY=""
  KFX_SIP_IDENTIFY_MATCH=""
  KFX_SIP_EXPIRATION="$PROVIDER_EXPIRATION_DEFAULT"
fi

echo
echo "==== Admin-Passwort (Linux admin + Samba admin) ===="
ask_yes_no ADMIN_PASSWORD_GENERATE "Sicheres Admin-Passwort automatisch generieren?" "y"
if [[ "$ADMIN_PASSWORD_GENERATE" == "y" ]]; then
  ADMIN_PASSWORD="$(generate_secure_password)"
  echo "[OK] Admin-Passwort wurde generiert. Es steht im Installationsbericht und root-only in ${ENVFILE}."
else
  echo "Admin-Passwort manuell eingeben (sichtbar aus = nein)."
  read_secret_twice ADMIN_PASSWORD "Admin-Passwort"
fi

read -r -p "FAX DID (Enter = ${SIP_NUMBER}): " FAX_DID_IN
FAX_DID="$(sanitize_digits "${FAX_DID_IN:-$SIP_NUMBER}")"
[[ -n "${FAX_DID}" ]] || die "FAX_DID darf nicht leer sein."
unset FAX_DID_IN

ask_default KFX_PRACTICE_NAME "Praxis-Kopfzeile fuer ausgehende Faxe" "KienzleFax"

ask_int_range FAX_PRINTER_COUNT "Anzahl Faxdrucker fax1..faxN" "5" "1" "100"
ask_int_range PDF_INPUT_COUNT "Anzahl PDF-zu-Fax-Eingaenge" "1" "1" "100"

ask_default SIP_BIND_PORT "SIP Bind Port (PJSIP extern; Provider-Config)" "${DEFAULT_SIP_BIND_PORT}"
[[ "$SIP_BIND_PORT" =~ ^[0-9]+$ ]] || die "SIP_BIND_PORT ungültig"

ask_default RTP_START "RTP Start-Port" "${DEFAULT_RTP_START}"
ask_default RTP_END   "RTP End-Port"   "${DEFAULT_RTP_END}"
[[ "$RTP_START" =~ ^[0-9]+$ ]] || die "RTP_START ungültig"
[[ "$RTP_END" =~ ^[0-9]+$ ]] || die "RTP_END ungültig"
[ "$RTP_START" -lt "$RTP_END" ] || die "RTP_START muss < RTP_END sein"

echo
echo "Hinweis Portweiterleitung nur fuer Fax-Kommunikation:"
echo "  UDP ${SIP_BIND_PORT} -> dieses System (SIP)"
echo "  UDP ${RTP_START}-${RTP_END} -> dieses System (RTP)"
echo "Eine feste IP per DHCP-Reservierung im Router wird empfohlen."

sep "Laufoptionen fuer diese Installation"
collect_run_options

KFX_HOSTNAME_ENV="$(quote_env_value "$KFX_HOSTNAME")"
PUBLIC_FQDN_ENV="$(quote_env_value "$PUBLIC_FQDN")"
KFX_PROVIDER_ENV="$(quote_env_value "$KFX_PROVIDER")"
KFX_PROVIDER_LABEL_ENV="$(quote_env_value "$KFX_PROVIDER_LABEL")"
SIP_USER_ENV="$(quote_env_value "$SIP_USER")"
KFX_SIP_DOMAIN_ENV="$(quote_env_value "$KFX_SIP_DOMAIN")"
KFX_SIP_OUTBOUND_PROXY_ENV="$(quote_env_value "$KFX_SIP_OUTBOUND_PROXY")"
KFX_SIP_IDENTIFY_MATCH_ENV="$(quote_env_value "$KFX_SIP_IDENTIFY_MATCH")"
SIP_PASSWORD_ENV="$(quote_env_value "$SIP_PASSWORD")"
ADMIN_PASSWORD_ENV="$(quote_env_value "$ADMIN_PASSWORD")"
KFX_PRACTICE_NAME_ENV="$(quote_env_value "$KFX_PRACTICE_NAME")"
KFX_CALLERID_NAME_ENV="$(quote_env_value "Fax")"
REMOVE_USER_NAME_ENV="$(quote_env_value "$REMOVE_USER_NAME")"

# AMI Secret NICHT interaktiv (lokal). Konfigurierbar via DEFAULT_AMI_SECRET oder später in ENVFILE.
AMI_SECRET="${DEFAULT_AMI_SECRET}"
AMI_SECRET_ENV="$(quote_env_value "$AMI_SECRET")"

ask_default AST_REF "Asterisk Git-Ref (Branch/Tag/Commit) für Build" "${ASTERISK_GIT_REF_DEFAULT}"
AST_REF_ENV="$(quote_env_value "$AST_REF")"

cat >"$ENVFILE" <<EENV
# generated by kienzlefax installer
KFX_HOSTNAME=${KFX_HOSTNAME_ENV}
KFX_PUBLIC_FQDN=${PUBLIC_FQDN_ENV}
KFX_PROVIDER=${KFX_PROVIDER_ENV}
KFX_PROVIDER_LABEL=${KFX_PROVIDER_LABEL_ENV}
KFX_SIP_USER=${SIP_USER_ENV}
KFX_SIP_DOMAIN=${KFX_SIP_DOMAIN_ENV}
KFX_SIP_OUTBOUND_PROXY=${KFX_SIP_OUTBOUND_PROXY_ENV}
KFX_SIP_IDENTIFY_MATCH=${KFX_SIP_IDENTIFY_MATCH_ENV}
KFX_SIP_EXPIRATION=${KFX_SIP_EXPIRATION}
KFX_PJSIP_ENDPOINT=kfx-provider-endpoint
KFX_SIP_NUMBER=${SIP_NUMBER}
KFX_SIP_PASSWORD=${SIP_PASSWORD_ENV}
KFX_ADMIN_PASSWORD=${ADMIN_PASSWORD_ENV}
KFX_FAX_DID=${FAX_DID}
KFX_AMI_SECRET=${AMI_SECRET_ENV}
KFX_SIP_BIND_PORT=${SIP_BIND_PORT}
KFX_RTP_START=${RTP_START}
KFX_RTP_END=${RTP_END}
KFX_FAX_PRINTER_COUNT=${FAX_PRINTER_COUNT}
KFX_PDF_INPUT_COUNT=${PDF_INPUT_COUNT}
KFX_AST_REF=${AST_REF_ENV}
KFX_REMOTE_REFRESH=${REMOTE_REFRESH}
KFX_WEB_REFRESH=${WEB_REFRESH}
KFX_ASTERISK_MANUAL_MENUSELECT=${AST_MANUAL_MENUSELECT}
KFX_REBUILD_ASTERISK=${AST_REBUILD}
KFX_INSTALL_REPORT_WITH_PASSWORDS=${INSTALL_REPORT}
KFX_REMOVE_USER_NAME=${REMOVE_USER_NAME_ENV}
KFX_REMOVE_USER_HOME=${REMOVE_USER_HOME}

# defaults used by dialplan module
KFX_CALLERID_NAME=${KFX_CALLERID_NAME_ENV}

# PDF header used by /usr/local/bin/pdf_with_header.sh
KFX_PRACTICE_NAME=${KFX_PRACTICE_NAME_ENV}
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
  ocrmypdf tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng \
  inotify-tools img2pdf python3-pikepdf unpaper \
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
ENVFILE="/etc/kienzlefax-installer.env"

if [[ -f "$ENVFILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
fi

FAX_PRINTER_COUNT="${KFX_FAX_PRINTER_COUNT:-5}"
PDF_INPUT_COUNT="${KFX_PDF_INPUT_COUNT:-1}"
if ! [[ "$FAX_PRINTER_COUNT" =~ ^[0-9]+$ ]] || (( FAX_PRINTER_COUNT < 1 || FAX_PRINTER_COUNT > 100 )); then
  FAX_PRINTER_COUNT=5
fi
if ! [[ "$PDF_INPUT_COUNT" =~ ^[0-9]+$ ]] || (( PDF_INPUT_COUNT < 1 || PDF_INPUT_COUNT > 100 )); then
  PDF_INPUT_COUNT=1
fi

sep "Verzeichnisse + Rechte (kienzlefax)"
mkdir -p "${KZ_BASE}"
for i in $(seq 1 "$FAX_PRINTER_COUNT"); do mkdir -p "${KZ_BASE}/incoming/fax${i}"; done
if (( PDF_INPUT_COUNT <= 1 )); then
  mkdir -p "${KZ_BASE}/pdf-zu-fax"
else
  for i in $(seq 1 "$PDF_INPUT_COUNT"); do mkdir -p "${KZ_BASE}/pdf-zu-fax${i}"; done
fi
mkdir -p "${KZ_BASE}/sendefehler/eingang" "${KZ_BASE}/sendefehler/berichte"
mkdir -p "${KZ_BASE}/staging" "${KZ_BASE}/queue" "${KZ_BASE}/processing"
mkdir -p "${KZ_BASE}/sendeberichte"
mkdir -p "${KZ_BASE}/config"
touch "${KZ_BASE}/phonebook.sqlite"

mkdir -p "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}"
chmod 0777 "${SPOOL_TIFF_DIR}" "${SPOOL_PDF_DIR}" || true
chmod 0777 "${KZ_BASE}" "${KZ_BASE}"/* || true
for i in $(seq 1 "$FAX_PRINTER_COUNT"); do chmod 0777 "${KZ_BASE}/incoming/fax${i}" || true; done
if (( PDF_INPUT_COUNT <= 1 )); then
  chmod 0777 "${KZ_BASE}/pdf-zu-fax" || true
else
  for i in $(seq 1 "$PDF_INPUT_COUNT"); do chmod 0777 "${KZ_BASE}/pdf-zu-fax${i}" || true; done
fi
chmod 0777 "${KZ_BASE}/sendefehler" "${KZ_BASE}/sendefehler"/* || true
chmod 0755 "${KZ_BASE}/config" || true

python3 - "$KZ_BASE" "$FAX_PRINTER_COUNT" "$PDF_INPUT_COUNT" <<'PY'
import json
import sys
from pathlib import Path

base = Path(sys.argv[1])
fax_count = int(sys.argv[2])
pdf_count = int(sys.argv[3])

sources = []
for i in range(1, fax_count + 1):
    sources.append({
        "id": f"fax{i}",
        "label": f"Faxdrucker {i}",
        "kind": "fax_printer",
        "path": str(base / "incoming" / f"fax{i}"),
        "enabled": True,
        "sendable": True,
        "order": i * 10,
    })

if pdf_count <= 1:
    sources.append({
        "id": "pdf-zu-fax",
        "label": "PDF zu Fax",
        "kind": "dropin",
        "path": str(base / "pdf-zu-fax"),
        "enabled": True,
        "sendable": True,
        "order": 1000,
    })
else:
    for i in range(1, pdf_count + 1):
        sources.append({
            "id": f"pdf-zu-fax{i}",
            "label": f"PDF zu Fax {i}",
            "kind": "dropin",
            "path": str(base / f"pdf-zu-fax{i}"),
            "enabled": True,
            "sendable": True,
            "order": 1000 + i,
        })

sources.append({
    "id": "sendefehler",
    "label": "Sendefehler",
    "kind": "failed_inbox",
    "path": str(base / "sendefehler" / "eingang"),
    "enabled": True,
    "sendable": True,
    "order": 9000,
})

out = base / "config" / "sources.json"
tmp = out.with_suffix(".json.tmp")
tmp.write_text(json.dumps({
    "schema_version": 1,
    "default_source": "fax1",
    "sources": sources,
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(out)
PY

chown root:www-data "${KZ_BASE}/config/sources.json" 2>/dev/null || chown root:root "${KZ_BASE}/config/sources.json" || true
chmod 0644 "${KZ_BASE}/config/sources.json" || true

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

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
set -a
source "$ENVFILE"
set +a

[[ -n "${KFX_ADMIN_PASSWORD:-}" ]] || die "KFX_ADMIN_PASSWORD fehlt in ${ENVFILE}; Optionen bitte neu setzen."

detect_source_ssh_user(){
  local cand=""
  cand="${SUDO_USER:-}"
  if [[ -z "$cand" || "$cand" == "root" || "$cand" == "admin" ]]; then
    cand="$(logname 2>/dev/null || true)"
  fi
  if [[ -n "$cand" && "$cand" != "root" && "$cand" != "admin" ]] && id "$cand" >/dev/null 2>&1; then
    printf '%s\n' "$cand"
  fi
}

copy_authorized_keys_to_admin(){
  local src_user src_home admin_home src_keys dst_keys
  src_user="$(detect_source_ssh_user || true)"
  [[ -n "$src_user" ]] || return 0

  src_home="$(getent passwd "$src_user" | cut -d: -f6 || true)"
  admin_home="$(getent passwd admin | cut -d: -f6 || true)"
  [[ -n "$src_home" && -n "$admin_home" ]] || return 0

  src_keys="${src_home}/.ssh/authorized_keys"
  dst_keys="${admin_home}/.ssh/authorized_keys"
  [[ -s "$src_keys" ]] || return 0

  install -d -m 0700 -o admin -g admin "${admin_home}/.ssh"
  touch "$dst_keys"
  chmod 0600 "$dst_keys"
  chown admin:admin "$dst_keys"

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    grep -Fxq "$key" "$dst_keys" 2>/dev/null || printf '%s\n' "$key" >>"$dst_keys"
  done <"$src_keys"

  chmod 0600 "$dst_keys"
  chown admin:admin "$dst_keys"
  log "[OK] SSH authorized_keys von '${src_user}' fuer admin uebernommen."
}

copy_authorized_keys_to_root(){
  local src_user src_home src_keys dst_keys
  src_user="$(detect_source_ssh_user || true)"
  [[ -n "$src_user" ]] || return 0

  src_home="$(getent passwd "$src_user" | cut -d: -f6 || true)"
  [[ -n "$src_home" ]] || return 0

  src_keys="${src_home}/.ssh/authorized_keys"
  dst_keys="/root/.ssh/authorized_keys"
  [[ -s "$src_keys" ]] || return 0

  install -d -m 0700 -o root -g root /root/.ssh
  touch "$dst_keys"
  chmod 0600 "$dst_keys"
  chown root:root "$dst_keys"

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    grep -Fxq "$key" "$dst_keys" 2>/dev/null || printf '%s\n' "$key" >>"$dst_keys"
  done <"$src_keys"

  chmod 0600 "$dst_keys"
  chown root:root "$dst_keys"
  log "[OK] SSH authorized_keys von '${src_user}' fuer root uebernommen."
}

sep "Admin-Account anlegen + sudo + Samba"
if ! id admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash admin
  log "[OK] User 'admin' angelegt."
fi

usermod -aG sudo admin
printf 'admin:%s\n' "$KFX_ADMIN_PASSWORD" | chpasswd

if ! id -nG admin | tr ' ' '\n' | grep -qx sudo; then
  die "User admin ist nicht in der Gruppe sudo."
fi

if command -v smbpasswd >/dev/null 2>&1; then
  if command -v pdbedit >/dev/null 2>&1 && pdbedit -L -u admin >/dev/null 2>&1; then
    printf '%s\n%s\n' "$KFX_ADMIN_PASSWORD" "$KFX_ADMIN_PASSWORD" | smbpasswd -s admin
  else
    printf '%s\n%s\n' "$KFX_ADMIN_PASSWORD" "$KFX_ADMIN_PASSWORD" | smbpasswd -a -s admin
  fi
  smbpasswd -e admin || true
else
  die "smbpasswd fehlt; Samba-Paketinstallation pruefen."
fi

copy_authorized_keys_to_admin
copy_authorized_keys_to_root

log "[OK] admin: Passwort, sudo und Samba gesetzt."
EOF
  chmod +x "${MOD_DIR}/30-admin-user.sh"

  # 40-web-ssl (kienzlefax.php optional reload)
  cat >"${MOD_DIR}/40-web-ssl.sh" <<'EOF'
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

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

WEBROOT="/var/www/html"
WEB_URL_RAW="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/kienzlefax.php"
FAXTON_URL="https://github.com/thomaskien/kienzlefax-fuer-linux/raw/refs/heads/main/faxton.mp3"

sep "Webroot bootstrappen (kienzlefax.php + faxton.mp3) + index redirect"
mkdir -p "${WEBROOT}"

KFXPHP="${WEBROOT}/kienzlefax.php"
DO_PHP="${KFX_WEB_REFRESH:-y}"
[[ -s "$KFXPHP" ]] || DO_PHP="y"
if [[ "$DO_PHP" == "y" ]]; then
  curl -fsSL -o "${KFXPHP}" "${WEB_URL_RAW}"
  log "[OK] kienzlefax.php geladen."
else
  [[ -s "$KFXPHP" ]] || die "kienzlefax.php fehlt, kann nicht übersprungen werden."
  log "[OK] kienzlefax.php unverändert."
fi

# faxton.mp3 konservativ: immer sicherstellen
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

  # 50-cups-samba (Bonjour/DNS-SD Freigabe)
  cat >"${MOD_DIR}/50-cups-samba.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

KZ_BASE="/srv/kienzlefax"
SPOOL_PDF_DIR="/var/spool/asterisk/fax"
ENVFILE="/etc/kienzlefax-installer.env"

if [[ -f "$ENVFILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
fi

FAX_PRINTER_COUNT="${KFX_FAX_PRINTER_COUNT:-5}"
PDF_INPUT_COUNT="${KFX_PDF_INPUT_COUNT:-1}"
if ! [[ "$FAX_PRINTER_COUNT" =~ ^[0-9]+$ ]] || (( FAX_PRINTER_COUNT < 1 || FAX_PRINTER_COUNT > 100 )); then
  FAX_PRINTER_COUNT=5
fi
if ! [[ "$PDF_INPUT_COUNT" =~ ^[0-9]+$ ]] || (( PDF_INPUT_COUNT < 1 || PDF_INPUT_COUNT > 100 )); then
  PDF_INPUT_COUNT=1
fi

sep "CUPS Backend + fax1..fax${FAX_PRINTER_COUNT} + Samba Shares"

if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "cups-browsed.service"; then
  systemctl stop cups-browsed || true
  systemctl disable cups-browsed || true
fi

if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "avahi-daemon.service"; then
  systemctl enable --now avahi-daemon || true
fi

BACKEND="/usr/lib/cups/backend/kienzlefaxpdf"
BACKEND_LOG="/var/log/kienzlefaxpdf-backend.log"

cat > "$BACKEND" <<'BACKEND_EOF'
#!/bin/bash
set -u
DESTBASE="/srv/kienzlefax/incoming"
FAX_COUNT="__KFX_FAX_PRINTER_COUNT__"
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
  for i in $(seq 1 "$FAX_COUNT"); do
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
[[ "$PRN" =~ ^fax[0-9]+$ ]] || { log "ERROR: invalid prn '$PRN'"; exit 1; }
PRN_NUM="${PRN#fax}"
[[ "$PRN_NUM" =~ ^[0-9]+$ ]] || { log "ERROR: invalid prn number '$PRN'"; exit 1; }
(( PRN_NUM >= 1 && PRN_NUM <= FAX_COUNT )) || { log "ERROR: prn '$PRN' outside configured range 1..$FAX_COUNT"; exit 1; }

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
if ! $TIMEOUT 60s $GS -q -dSAFER -dBATCH -dNOPAUSE \
  -sDEVICE=pdfwrite -sPAPERSIZE=a4 -dFIXEDMEDIA -dPDFFitPage \
  -sOutputFile="$tmp_pdf" "$infile" >>"$LOG" 2>&1; then
  rc=$?
  log "ERROR: gs failed rc=$rc"
  rm -f "$tmp_pdf"
  [[ -n "$tmp_in" ]] && rm -f "$tmp_in"
  exit 1
fi

$MV -f "$tmp_pdf" "$out" || { log "ERROR: mv failed"; rm -f "$tmp_pdf"; [[ -n "$tmp_in" ]] && rm -f "$tmp_in"; exit 1; }
$CHMOD 0666 "$out" || true
[[ -n "$tmp_in" ]] && rm -f "$tmp_in" || true
log "OK wrote '$out'"
exit 0
BACKEND_EOF

chmod 0755 "$BACKEND"
chown root:root "$BACKEND"
sed -i "s/__KFX_FAX_PRINTER_COUNT__/${FAX_PRINTER_COUNT}/g" "$BACKEND"

touch "$BACKEND_LOG"
chown lp:lp "$BACKEND_LOG" || true
chmod 0664 "$BACKEND_LOG"

for i in $(seq 1 "$FAX_PRINTER_COUNT"); do
  mkdir -p "${KZ_BASE}/incoming/fax${i}"
  chmod 0777 "${KZ_BASE}/incoming/fax${i}" || true
done
if (( PDF_INPUT_COUNT <= 1 )); then
  mkdir -p "${KZ_BASE}/pdf-zu-fax"
  chmod 0777 "${KZ_BASE}/pdf-zu-fax" || true
else
  for i in $(seq 1 "$PDF_INPUT_COUNT"); do
    mkdir -p "${KZ_BASE}/pdf-zu-fax${i}"
    chmod 0777 "${KZ_BASE}/pdf-zu-fax${i}" || true
  done
fi

systemctl enable --now cups || true
systemctl restart cups || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lpstat -r >/dev/null 2>&1 && break
  sleep 1
done

if ! cupsctl --share-printers; then
  log "[WARN] CUPS-Druckerfreigabe konnte nicht global aktiviert werden."
fi
if ! cupsctl Browsing=Yes BrowseLocalProtocols=dnssd BrowseDNSSDSubTypes=_cups,_print DefaultShared=Yes IdleExitTimeout=0; then
  log "[WARN] CUPS-Bonjour-Optionen konnten nicht vollstaendig gesetzt werden."
fi

MODEL="drv:///sample.drv/generic.ppd"
if ! lpinfo -m 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  MODEL="raw"
  log "[WARN] CUPS generic.ppd nicht gefunden; verwende raw als Fallback."
fi

for i in $(seq 1 100); do lpadmin -x "fax$i" 2>/dev/null || true; done
for i in $(seq 1 "$FAX_PRINTER_COUNT"); do
  PRN="fax$i"
  lpadmin -p "$PRN" -E -v "kienzlefaxpdf:/$PRN" -m "$MODEL"
  lpadmin -p "$PRN" -o printer-is-shared=true
  lpadmin -p "$PRN" -o media=A4
  lpadmin -p "$PRN" -o PageSize=A4
  cupsenable "$PRN"
  cupsaccept "$PRN"
done

cupsctl --share-printers || true
systemctl restart cups || true
if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "avahi-daemon.service"; then
  systemctl restart avahi-daemon || true
fi

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
EOFSMB

append_pdf_share(){
  local share="$1"
  local path="$2"
  cat >> /etc/samba/smb.conf <<EOFSMB

[${share}]
   path = ${path}
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
   force group = nogroup
   create mask = 0666
   directory mask = 2777
EOFSMB
}

if (( PDF_INPUT_COUNT <= 1 )); then
  append_pdf_share "pdf-zu-fax" "/srv/kienzlefax/pdf-zu-fax"
else
  for i in $(seq 1 "$PDF_INPUT_COUNT"); do
    append_pdf_share "pdf-zu-fax${i}" "/srv/kienzlefax/pdf-zu-fax${i}"
  done
fi

cat >> /etc/samba/smb.conf <<EOFSMB

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

  # 60-asterisk-build (unverändert)
  cat >"${MOD_DIR}/60-asterisk-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

wait_for_asterisk_cli(){
  local timeout="${1:-90}"
  local waited=0
  command -v asterisk >/dev/null 2>&1 || return 1
  while (( waited < timeout )); do
    if asterisk -rx "core show version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

install_asterisk_systemd_unit(){
  cat >/etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
ExecReload=/usr/sbin/asterisk -rx "core reload"
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 /etc/systemd/system/asterisk.service
  systemctl daemon-reload
}

asterisk_build_jobs(){
  local n jobs
  n="$(nproc 2>/dev/null || echo 2)"
  jobs="${KFX_ASTERISK_BUILD_JOBS:-}"
  if [[ -z "$jobs" ]]; then
    jobs="$n"
    if (( jobs > 2 )); then
      jobs=2
    fi
  fi
  if ! [[ "$jobs" =~ ^[0-9]+$ ]] || (( jobs < 1 )); then
    jobs=1
  fi
  printf '%s\n' "$jobs"
}

make_asterisk_with_retry(){
  local jobs="$1"
  log "[INFO] Asterisk Build startet mit make -j${jobs}."
  if make -j"$jobs"; then
    return 0
  fi

  log "[WARN] Asterisk Build mit -j${jobs} fehlgeschlagen. Retry konservativ mit make -j1."
  journalctl -k -n 80 --no-pager 2>/dev/null | grep -Ei 'out of memory|oom|killed process|cc1' || true
  make -j1
}

configure_asterisk_modules(){
  local ms="./menuselect/menuselect"
  local failed=0
  make menuselect.makeopts
  [[ -x "$ms" ]] || die "menuselect CLI fehlt: $ms"

  for mod in res_fax res_fax_spandsp; do
    if ! "$ms" --enable "$mod" menuselect.makeopts; then
      log "[WARN] Asterisk-Pflichtmodul konnte nicht automatisch aktiviert werden: $mod"
      failed=1
    fi
  done

  for mod in app_fax format_tiff; do
    if ! "$ms" --enable "$mod" menuselect.makeopts; then
      log "[INFO] Asterisk-Option ist in diesem Source-Tree nicht vorhanden oder nicht separat waehlbar: $mod"
    fi
  done

  if ! "$ms" --check-deps menuselect.makeopts; then
    log "[WARN] Asterisk-menuselect meldet fehlende Abhaengigkeiten."
    failed=1
  fi

  if [[ "${KFX_ASTERISK_MANUAL_MENUSELECT:-n}" == "y" ]]; then
    echo
    echo "Manuelle Asterisk-Modulpruefung. Beenden/Speichern im Menue mit X."
    make menuselect
    "$ms" --check-deps menuselect.makeopts
    failed=0
  fi

  if [[ "$failed" != "0" ]]; then
    die "Asterisk-Fax-Module konnten nicht automatisch aktiviert werden. Installer erneut starten und manuelle Asterisk-Modulpruefung mit y waehlen."
  fi
}

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

ASTERISK_SRC_DIR="/usr/src/asterisk"
ASTERISK_GIT_URL="https://github.com/asterisk/asterisk.git"

sep "Asterisk: Source holen + Build (Fax-Module nichtinteraktiv)"
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

configure_asterisk_modules

BUILD_JOBS="$(asterisk_build_jobs)"
make_asterisk_with_retry "$BUILD_JOBS"
make install
make samples || true
if command -v timeout >/dev/null 2>&1; then
  timeout 30s make config || log "[WARN] make config nicht erfolgreich/Timeout; native systemd-Unit wird verwendet."
else
  make config || true
fi
install_asterisk_systemd_unit
ldconfig

systemctl reset-failed asterisk || true
systemctl enable --now asterisk
wait_for_asterisk_cli 90 || die "Asterisk wurde gestartet, aber die CLI/der Control-Socket ist nicht bereit."
log "[OK] Asterisk installiert/gestartet."
EOF
  chmod +x "${MOD_DIR}/60-asterisk-build.sh"

  # 70-rtp-ami
  cat >"${MOD_DIR}/70-rtp-ami.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

wait_for_asterisk_cli(){
  local timeout="${1:-60}"
  local waited=0
  command -v asterisk >/dev/null 2>&1 || return 1
  while (( waited < timeout )); do
    if asterisk -rx "core show version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

RTP_CONF="/etc/asterisk/rtp.conf"
MANAGER_CONF="/etc/asterisk/manager.conf"
MODULES_CONF="/etc/asterisk/modules.conf"

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

ensure_capacity_modules_in_modules_conf(){
  mkdir -p /etc/asterisk
  if [[ -f "$MODULES_CONF" ]]; then
    cp -a "$MODULES_CONF" "${MODULES_CONF}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" || true
  fi
  touch "$MODULES_CONF"

  python3 - "$MODULES_CONF" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8") if path.exists() else ""
lines = text.splitlines()
wanted = ["func_groupcount.so", "func_lock.so"]
section_re = re.compile(r"^\s*\[([^\]]+)\]\s*$")
module_re = re.compile(r"^\s*(?:load|noload)\s*=>\s*(\S+)\s*$", re.I)

modules_idx = None
for i, line in enumerate(lines):
    m = section_re.match(line)
    if m and m.group(1).strip().lower() == "modules":
        modules_idx = i
        break

if modules_idx is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(["[modules]"])
    modules_idx = len(lines) - 1

end = len(lines)
for i in range(modules_idx + 1, len(lines)):
    if section_re.match(lines[i]):
        end = i
        break

kept = []
seen = set()
for line in lines[modules_idx + 1:end]:
    m = module_re.match(line)
    if m and m.group(1) in wanted:
        mod = m.group(1)
        if mod not in seen:
            kept.append(f"load => {mod}")
            seen.add(mod)
        continue
    kept.append(line)

insert = [f"load => {mod}" for mod in wanted if mod not in seen]
insert_at = 0
for idx, line in enumerate(kept):
    if re.match(r"^\s*autoload\s*=", line, re.I):
        insert_at = idx + 1
lines = (
    lines[:modules_idx + 1]
    + kept[:insert_at]
    + insert
    + kept[insert_at:]
    + lines[end:]
)
path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

ensure_capacity_modules_running(){
  ensure_capacity_modules_in_modules_conf

  wait_for_asterisk_cli 60 || die "Asterisk CLI ist nicht bereit; Kapazitaetsmodule koennen nicht geprueft werden."
  asterisk -rx "module load func_groupcount.so" >/dev/null 2>&1 || true
  asterisk -rx "module load func_lock.so" >/dev/null 2>&1 || true

  local group_out lock_out
  group_out="$(asterisk -rx "module show like func_groupcount" || true)"
  lock_out="$(asterisk -rx "module show like func_lock" || true)"

  [[ "$group_out" == *"func_groupcount.so"* && "$group_out" == *"Running"* ]] \
    || die "func_groupcount.so ist nicht geladen."
  [[ "$lock_out" == *"func_lock.so"* && "$lock_out" == *"Running"* ]] \
    || die "func_lock.so ist nicht geladen."
}

sep "Asterisk: Kapazitaetsmodule dauerhaft laden"
ensure_capacity_modules_running

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

if wait_for_asterisk_cli 60; then
  asterisk -rx "manager reload" || true
  asterisk -rx "manager show settings" | sed -n '1,200p' || true
  asterisk -rx "manager show user kfx" || true
else
  log "[WARN] Asterisk CLI nicht bereit; Manager-Reload/Checks übersprungen."
fi

log "[OK] RTP+AMI konfiguriert."
EOF
  chmod +x "${MOD_DIR}/70-rtp-ami.sh"

  # 90-worker-unit (NEU)
  cat >"${MOD_DIR}/90-worker-unit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

sep "Worker: /etc/default + systemd Unit (EnvironmentFile)"
install -d /etc/default

quote_env_value(){
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$/\\$}"
  s="${s//\`/\\\`}"
  printf '"%s"' "$s"
}

PRACTICE_NAME_ENV="$(quote_env_value "${KFX_PRACTICE_NAME:-KienzleFax}")"

cat >/etc/default/kienzlefax-worker <<EOFENV
# kienzlefax-worker env
KFX_BASE=/srv/kienzlefax

KFX_AMI_HOST=127.0.0.1
KFX_AMI_PORT=5038
KFX_AMI_USER=kfx
KFX_AMI_PASS=${KFX_AMI_SECRET}

KFX_DIAL_CONTEXT=fax-out
PRACTICE_NAME=${PRACTICE_NAME_ENV}

# optional tuning
KFX_MAX_INFLIGHT=2
KFX_POST_CALL_COOLDOWN_SEC=20
EOFENV
chmod 0600 /etc/default/kienzlefax-worker
chown root:root /etc/default/kienzlefax-worker

cat >/etc/systemd/system/kienzlefax-worker.service <<'EOFSVC'
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
EOFSVC

chmod 0644 /etc/systemd/system/kienzlefax-worker.service
chown root:root /etc/systemd/system/kienzlefax-worker.service

systemctl daemon-reload
systemctl enable --now kienzlefax-worker

log "[OK] Worker Unit aktiv."
EOF
  chmod +x "${MOD_DIR}/90-worker-unit.sh"

  # 95-install-report
  cat >"${MOD_DIR}/95-install-report.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
set -a
source "$ENVFILE"
set +a

if [[ "${KFX_INSTALL_REPORT_WITH_PASSWORDS:-y}" != "y" ]]; then
  log "[OK] Installationsbericht mit Passwoertern wurde abgewählt."
  exit 0
fi

OUT_DIR="/var/spool/asterisk/fax"
install -d -m 0777 "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT_DIR}/installationsbericht_kienzlefax_${STAMP}_bitte_loeschen_mit_passwoertern.pdf"
HOST="$(hostname 2>/dev/null || echo "${KFX_HOSTNAME:-kienzlefax}")"
IPS="$(hostname -I 2>/dev/null | xargs || true)"
[[ -n "$IPS" ]] || IPS="nicht ermittelt"

if ! HOST="$HOST" IPS="$IPS" python3 - "$OUT" <<'PY'
import os
import sys
import textwrap
from datetime import datetime

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas

out = sys.argv[1]
env = os.environ

def e(name, default=""):
    return env.get(name, default)

generated = datetime.now().astimezone().replace(microsecond=0).isoformat()
hostname = env.get("HOST", "")
ips = env.get("IPS", "")

lines = [
    "KienzleFax Installationsbericht",
    "BITTE LOESCHEN: Dieses Dokument enthaelt Passwoerter im Klartext.",
    "",
    f"Erzeugt: {generated}",
    f"Hostname: {hostname}",
    f"Aktuelle lokale IP-Adresse(n): {ips}",
    "",
    "Empfehlung Netzwerk:",
    "- Fuer stabile Portweiterleitungen im Router eine feste IP per DHCP-Reservierung setzen.",
    "- Die Portweiterleitungen sollen auf diese reservierte IP zeigen.",
    "- DynDNS/Public FQDN ist optional, zur optimalen Stabilitaet aber unbedingt empfohlen.",
    "",
    "Provider-Hinweis:",
    f"- Ausgewaehlter Provider: {e('KFX_PROVIDER_LABEL', e('KFX_PROVIDER', '1&1 Deutschland'))}",
    f"- SIP Registrar/Domain: {e('KFX_SIP_DOMAIN', '-')}",
    "- Providerabhaengige Dateien: /etc/asterisk/pjsip.conf und /etc/asterisk/extensions.conf.",
    "- Installer-Module dazu: installer-modular/pjsip-provider.sh und installer-modular/extensions.sh.",
    "- Bei Provider 'manuell' wird pjsip.conf nicht automatisch geschrieben.",
    "",
    "Zugangsdaten:",
    f"- SIP Benutzer/Auth-ID: {e('KFX_SIP_USER', e('KFX_SIP_NUMBER'))}",
    f"- SIP Nummer / CallerID: {e('KFX_SIP_NUMBER')}",
    f"- SIP Passwort: {e('KFX_SIP_PASSWORD')}",
    "- Linux Benutzer: admin",
    f"- Admin Passwort: {e('KFX_ADMIN_PASSWORD')}",
    "- Samba Benutzer: admin",
    "- Samba Passwort: identisch mit Admin Passwort",
    "",
    "Fax-Portweiterleitungen im Router, nur fuer Fax-Kommunikation:",
    f"- UDP {e('KFX_SIP_BIND_PORT', '5070')} -> KienzleFax-System (SIP/PJSIP)",
    f"- UDP {e('KFX_RTP_START', '12000')}-{e('KFX_RTP_END', '12049')} -> KienzleFax-System (RTP)",
    "- Web-Ports 80/443 NIEMALS ins Internet weiterleiten: Das wuerde Patientendaten exponieren.",
    "",
    "Wichtige Dateien:",
    "- /etc/kienzlefax-installer.env",
    "- /etc/asterisk/pjsip.conf",
    "- /etc/asterisk/extensions.conf",
    "- /etc/asterisk/manager.conf",
    "- /etc/default/kienzlefax-worker",
    "- /etc/samba/smb.conf",
    "- /etc/cups/cupsd.conf",
    "- /usr/local/bin/kienzlefax-worker.py",
    "- /usr/local/bin/pdf_with_header.sh",
    "- /usr/local/bin/scan-ocr-watch.sh",
    "- /srv/kienzlefax/config/sources.json",
    "",
    "Samba-Shares und Verzeichnisse:",
    f"- Faxdrucker: fax1..fax{e('KFX_FAX_PRINTER_COUNT', '5')} -> /srv/kienzlefax/incoming/fax1..faxN",
    f"- PDF-zu-Fax-Eingaenge: {e('KFX_PDF_INPUT_COUNT', '1')} (Standard bei 1: pdf-zu-fax)",
    "- fax-eingang -> /var/spool/asterisk/fax",
    "- hierhin-scannen-fuer-ocr -> /srv/scan/eingang",
    "- scan-eingang -> /srv/scan/ocr",
    "",
    "Weitere Verzeichnisse:",
    "- Sendeberichte: /srv/kienzlefax/sendeberichte",
    "- Sendefehler Eingang: /srv/kienzlefax/sendefehler/eingang",
    "- Sendefehler Berichte: /srv/kienzlefax/sendefehler/berichte",
    "- Interne Queue: /srv/kienzlefax/queue",
    "- Interne Verarbeitung: /srv/kienzlefax/processing",
    "- Fax-OCR Eingang intern: /srv/scan/fax-eingang",
    "- Fax-OCR Archiv intern: /srv/scan/fax-archiv",
]

c = canvas.Canvas(out, pagesize=A4)
w, h = A4
left = 18 * mm
top = h - 18 * mm
bottom = 16 * mm
y = top

def draw_line(text, bold=False):
    global y
    if y < bottom:
        c.showPage()
        y = top
    c.setFont("Helvetica-Bold" if bold else "Helvetica", 11 if bold else 9)
    c.drawString(left, y, text)
    y -= 5.2 * mm

for idx, line in enumerate(lines):
    if line == "":
        y -= 2.5 * mm
        continue
    wrapped = textwrap.wrap(line, width=95) or [line]
    for part_idx, part in enumerate(wrapped):
        draw_line(part, bold=(idx == 0 or line.startswith("BITTE LOESCHEN")))

c.save()
PY
then
  log "[WARN] Installationsbericht konnte nicht als PDF erzeugt werden."
  exit 0
fi

chmod 0666 "$OUT" || true
log "[OK] Installationsbericht erzeugt: $OUT"
log "[WARN] Dieser Bericht enthaelt Passwoerter im Klartext und sollte nach der Dokumentation geloescht werden."
EOF
  chmod +x "${MOD_DIR}/95-install-report.sh"

  # 96-remove-initial-user
  cat >"${MOD_DIR}/96-remove-initial-user.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

ENVFILE="/etc/kienzlefax-installer.env"
[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

[[ -n "${KFX_REMOVE_USER_NAME:-}" ]] || exit 0

sep "Optionaler Benutzer-Abschluss"
case "$KFX_REMOVE_USER_NAME" in
  root|admin) die "Sicherheitsabbruch: Benutzer '${KFX_REMOVE_USER_NAME}' darf nicht entfernt werden.";;
esac

disable_user_login(){
  local user="$1" home shell stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  log "[WARN] Deaktiviere Login fuer Benutzer '${user}', weil vollstaendiges Loeschen momentan nicht moeglich ist."

  passwd -l "$user" >/dev/null 2>&1 || true
  chage -E 0 "$user" >/dev/null 2>&1 || true
  gpasswd -d "$user" sudo >/dev/null 2>&1 || true

  shell="/usr/sbin/nologin"
  [[ -x "$shell" ]] || shell="$(command -v nologin 2>/dev/null || true)"
  if [[ -n "$shell" && -x "$shell" ]]; then
    usermod -s "$shell" "$user" >/dev/null 2>&1 || true
  fi

  home="$(getent passwd "$user" | cut -d: -f6 || true)"
  if [[ -n "$home" && -f "${home}/.ssh/authorized_keys" ]]; then
    mv "${home}/.ssh/authorized_keys" "${home}/.ssh/authorized_keys.disabled-kienzlefax.${stamp}" 2>/dev/null || true
  fi
}

id admin >/dev/null 2>&1 || die "admin existiert nicht; Benutzer '${KFX_REMOVE_USER_NAME}' wird nicht entfernt."
if ! id -nG admin | tr ' ' '\n' | grep -qx sudo; then
  die "admin ist nicht in sudo; Benutzer '${KFX_REMOVE_USER_NAME}' wird nicht entfernt."
fi

if id "$KFX_REMOVE_USER_NAME" >/dev/null 2>&1; then
  if [[ "${KFX_REMOVE_USER_HOME:-n}" == "y" ]]; then
    if ! userdel -r "$KFX_REMOVE_USER_NAME"; then
      log "[WARN] Benutzer '${KFX_REMOVE_USER_NAME}' konnte nicht entfernt werden. Vermutlich laufen noch Prozesse dieses Benutzers."
      disable_user_login "$KFX_REMOVE_USER_NAME"
    fi
  else
    if ! userdel "$KFX_REMOVE_USER_NAME"; then
      log "[WARN] Benutzer '${KFX_REMOVE_USER_NAME}' konnte nicht entfernt werden. Vermutlich laufen noch Prozesse dieses Benutzers."
      disable_user_login "$KFX_REMOVE_USER_NAME"
    fi
  fi
else
  log "[OK] Benutzer '${KFX_REMOVE_USER_NAME}' existiert nicht mehr."
fi
EOF
  chmod +x "${MOD_DIR}/96-remove-initial-user.sh"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
require_root
export DEBIAN_FRONTEND=noninteractive

sep "Bootstrap lokale Module"
bootstrap_local_modules

sep "Optionen sammeln"
run_module "${MOD_DIR}/00-base.sh"

# Load ENV early so the remaining installation can run without further prompts.
# shellcheck disable=SC1090
source "$ENVFILE"

sep "Remote Module holen/aktualisieren"
maybe_fetch_one "extensions.sh"      "$URL_EXTENSIONS"      "${MOD_CACHE}/extensions.sh"
maybe_fetch_one "pjsip-provider.sh"  "$URL_PJSIP_PROVIDER"  "${MOD_CACHE}/pjsip-provider.sh"
maybe_fetch_one "worker.sh"          "$URL_WORKER"          "${MOD_CACHE}/worker.sh"
maybe_fetch_one "agi.sh"             "$URL_AGI"             "${MOD_CACHE}/agi.sh"
maybe_fetch_one "pdf_with_header.sh" "$URL_PDF_WITH_HEADER" "${MOD_CACHE}/pdf_with_header.sh"
maybe_fetch_one "scan_ocr.sh"        "$URL_SCAN_OCR"        "${MOD_CACHE}/scan_ocr.sh"

sep "Module ausführen (feste Reihenfolge)"
run_module "${MOD_DIR}/10-packages.sh"
run_module "${MOD_DIR}/20-dirs-acl.sh"
run_module "${MOD_DIR}/30-admin-user.sh"
run_module "${MOD_DIR}/40-web-ssl.sh"
run_module "${MOD_DIR}/50-cups-samba.sh"

sep "Remote Scan-OCR installieren"
run_remote_script "${MOD_CACHE}/scan_ocr.sh"

DO_ASTERISK_BUILD="${KFX_REBUILD_ASTERISK:-y}"
if [[ "$DO_ASTERISK_BUILD" == "y" ]]; then
  run_module "${MOD_DIR}/60-asterisk-build.sh"
else
  sep "Asterisk Build übersprungen (bestehende Installation wird genutzt)"
  install_native_asterisk_unit
  systemctl reset-failed asterisk || true
  systemctl enable --now asterisk || true
fi

require_asterisk_cli 90
run_module "${MOD_DIR}/70-rtp-ami.sh"

# Load ENV
# shellcheck disable=SC1090
source "$ENVFILE"

# ------------------------------------------------------------------------------
# Export variables for remote scripts (compatibility layer)
# ------------------------------------------------------------------------------
export KFX_HOSTNAME KFX_PUBLIC_FQDN KFX_PROVIDER KFX_PROVIDER_LABEL
export KFX_SIP_USER KFX_SIP_NUMBER KFX_SIP_PASSWORD KFX_SIP_DOMAIN KFX_SIP_OUTBOUND_PROXY KFX_SIP_IDENTIFY_MATCH KFX_SIP_EXPIRATION
export KFX_FAX_DID KFX_SIP_BIND_PORT KFX_PJSIP_ENDPOINT
export KFX_RTP_START KFX_RTP_END KFX_AST_REF KFX_AMI_SECRET

# Common legacy names (remote scripts may still use these)
export PJSIP_USER="${PJSIP_USER:-${KFX_SIP_USER:-$KFX_SIP_NUMBER}}"
export PJSIP_PASS="${PJSIP_PASS:-$KFX_SIP_PASSWORD}"
export PJSIP_EXPIRATION="${PJSIP_EXPIRATION:-${KFX_SIP_EXPIRATION:-300}}"
export PJSIP_OUTBOUND_PROXY="${PJSIP_OUTBOUND_PROXY:-${KFX_SIP_OUTBOUND_PROXY:-}}"
export PJSIP_IDENTIFY_MATCH="${PJSIP_IDENTIFY_MATCH:-${KFX_SIP_IDENTIFY_MATCH:-}}"
export SIP_BIND_PORT="${SIP_BIND_PORT:-$KFX_SIP_BIND_PORT}"
export SIP_PORT="${SIP_PORT:-$KFX_SIP_BIND_PORT}"
export FAX_DID="${FAX_DID:-$KFX_FAX_DID}"
export PUBLIC_FQDN="${PUBLIC_FQDN:-$KFX_PUBLIC_FQDN}"

# AMI env for worker scripts (remote scripts might still look for these)
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
if [[ "${KFX_PROVIDER:-1und1}" == "manual" ]]; then
  log "[INFO] Provider manuell gewaehlt; pjsip.conf wird nicht automatisch geschrieben."
else
  run_remote_script "${MOD_CACHE}/pjsip-provider.sh"
  asterisk_rx "pjsip reload"
fi

sep "Remote Dialplan (befüllt extensions.conf)"
run_remote_script "${MOD_CACHE}/extensions.sh"
asterisk_rx "dialplan reload"

sep "Remote AGI installieren"
run_remote_script "${MOD_CACHE}/agi.sh"

sep "Remote Worker installieren (nur Datei/Code)"
run_remote_script "${MOD_CACHE}/worker.sh"

sep "Worker: /etc/default + systemd Unit (EnvironmentFile)"
run_module "${MOD_DIR}/90-worker-unit.sh"

sep "Remote pdf_with_header.sh installieren"
run_remote_script "${MOD_CACHE}/pdf_with_header.sh"

sep "Installationsbericht"
run_module "${MOD_DIR}/95-install-report.sh"
run_module "${MOD_DIR}/96-remove-initial-user.sh"

sep "Reloads + Status"
asterisk_rx "core reload"
asterisk_rx "module show like func_groupcount"
asterisk_rx "module show like func_lock"
asterisk_rx "pjsip reload"
asterisk_rx "dialplan reload"

systemctl status apache2 --no-pager -l || true
systemctl status cups --no-pager -l || true
systemctl status smbd --no-pager -l || true
systemctl status scan-ocr --no-pager -l || true
systemctl status scan-ocr-fax --no-pager -l || true
systemctl status asterisk --no-pager -l || true
systemctl status kienzlefax-worker --no-pager -l || true

sep "Fertig: Kurzinfo"
echo "Hostname: $(hostname)"
echo "Web: http://$(hostname)/ -> /kienzlefax.php"
echo "Web SSL (self-signed 50y): https://$(hostname)/"
echo "SIP Bind Port (Provider): ${KFX_SIP_BIND_PORT}"
echo "RTP: ${KFX_RTP_START}-${KFX_RTP_END}"
echo "AMI: 127.0.0.1:5038 user=kfx (secret in /etc/default/kienzlefax-worker)"
if [[ "${KFX_INSTALL_REPORT_WITH_PASSWORDS:-y}" == "y" ]]; then
  echo "Installationsbericht: /var/spool/asterisk/fax/installationsbericht_kienzlefax_*_bitte_loeschen_mit_passwoertern.pdf"
fi
echo "Remote module cache: ${MOD_CACHE}"

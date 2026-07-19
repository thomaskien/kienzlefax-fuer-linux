#!/usr/bin/env bash
# IMMER verwenden wenn die optionale Asterisk-Telefoniewarteschlange installiert, aktualisiert oder deaktiviert wird.
set -euo pipefail

ENVFILE="${KFX_INSTALLER_ENVFILE:-/etc/kienzlefax-installer.env}"
ASTERISK_ETC="${KFX_ASTERISK_ETC:-/etc/asterisk}"
GERMAN_SOUND_SOURCE="${KFX_GERMAN_SOUND_SOURCE:-/usr/share/asterisk/sounds/de}"
PJSIP_MAIN="${ASTERISK_ETC}/pjsip.conf"
EXTENSIONS_MAIN="${ASTERISK_ETC}/extensions.conf"
QUEUES_MAIN="${ASTERISK_ETC}/queues.conf"
QUEUE_RULES_MAIN="${ASTERISK_ETC}/queuerules.conf"
PJSIP_PHONE="${ASTERISK_ETC}/pjsip-kfx-telefonie.conf"
EXTENSIONS_PHONE="${ASTERISK_ETC}/extensions-kfx-telefonie.conf"
QUEUES_PHONE="${ASTERISK_ETC}/queues-kfx.conf"
QUEUE_RULES_PHONE="${ASTERISK_ETC}/queuerules-kfx.conf"
PJSIP_INCLUDE="#tryinclude \"${PJSIP_PHONE}\""
EXTENSIONS_INCLUDE="#tryinclude \"${EXTENSIONS_PHONE}\""
QUEUES_INCLUDE="#include \"${QUEUES_PHONE}\""
QUEUE_RULES_INCLUDE="#include \"${QUEUE_RULES_PHONE}\""

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date -Is)] $*"; }
sep(){ echo; echo "======================================================================"; echo "== $*"; echo "======================================================================"; }

[[ -f "$ENVFILE" ]] || die "ENV fehlt: $ENVFILE"
# shellcheck disable=SC1090
source "$ENVFILE"

PHONE_ENABLED="${KFX_PHONE_QUEUE_ENABLED:-n}"
QUEUE_ONLY="${KFX_QUEUE_ONLY:-n}"
PHONE_COUNT="${KFX_PHONE_COUNT:-0}"
FIRST_EXTENSION="${KFX_PHONE_FIRST_EXTENSION:-201}"
PHONE_PORT="${KFX_PHONE_INTERNAL_PORT:-5060}"
PHONE_BIND_IP="${KFX_PHONE_BIND_IP:-}"
PHONE_LOCAL_CIDR="${KFX_PHONE_LOCAL_CIDR:-}"
PHONE_REMOTE_ACCESS_ENABLED="${KFX_PHONE_REMOTE_ACCESS_ENABLED:-n}"
PHONE_ALLOWED_CIDR="${KFX_PHONE_ALLOWED_CIDR:-$PHONE_LOCAL_CIDR}"
PROVIDER_CHANNEL_LIMIT="${KFX_PROVIDER_CHANNEL_LIMIT:-4}"
PROVIDER_PHONE_LIMIT="${KFX_PROVIDER_PHONE_LIMIT:-3}"
PROVIDER_FAX_LIMIT="${KFX_PROVIDER_FAX_LIMIT:-3}"
QUEUE_MAX_WAITING="${KFX_QUEUE_MAX_WAITING:-5}"
PHONE_OUT_COUNTS_PROVIDER_LIMIT="${KFX_PHONE_OUT_COUNTS_PROVIDER_LIMIT:-y}"
SIPGATE_OVERFLOW_ENABLED="${KFX_SIPGATE_OVERFLOW_ENABLED:-n}"
SIPGATE_OVERFLOW_CHANNEL_LIMIT="${KFX_SIPGATE_OVERFLOW_CHANNEL_LIMIT:-2}"
SIPGATE_OVERFLOW_DOMAIN="${KFX_SIPGATE_OVERFLOW_DOMAIN:-sipconnect.sipgate.de}"
SIPGATE_OVERFLOW_IDENTIFY_MATCH="${KFX_SIPGATE_OVERFLOW_IDENTIFY_MATCH:-217.10.68.150}"

mkdir -p "$ASTERISK_ETC"

backup_file(){
  local file="$1"
  if [[ -e "$file" ]]; then
    cp -a "$file" "${file}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
  fi
}

install_generated_file(){
  local tmp="$1" target="$2" mode="$3"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
  backup_file "$target"
  mv -f "$tmp" "$target"
  chmod "$mode" "$target"
  if getent group asterisk >/dev/null 2>&1; then
    chown root:asterisk "$target" 2>/dev/null || true
  else
    chown root:root "$target" 2>/dev/null || true
  fi
  return 0
}

ensure_include(){
  local file="$1" include="$2"
  touch "$file"
  if grep -Fxq "$include" "$file" 2>/dev/null; then
    return 1
  fi
  backup_file "$file"
  printf '\n%s\n' "$include" >>"$file"
  return 0
}

wait_for_asterisk_cli(){
  local timeout="${1:-90}" waited=0
  while (( waited < timeout )); do
    if asterisk -rx "core show version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

active_channel_count(){
  asterisk -rx "core show channels count" 2>/dev/null \
    | awk '/active channels/ {print $1; found=1; exit} END {if (!found) print 0}'
}

phone_transport_listening(){
  local target="${PHONE_BIND_IP}:${PHONE_PORT}"
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -lunp 2>/dev/null \
    | awk -v target="$target" '
        index($0, target) && index($0, "asterisk") {found=1}
        END {exit(found ? 0 : 1)}
      '
}

ast_cfg_value(){
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//;/\\;}"
  printf '%s' "$value"
}

env_value(){
  local name="$1"
  printf '%s' "${!name-}"
}

validate_phone_settings(){
  [[ "$PHONE_COUNT" =~ ^[0-9]+$ ]] && (( PHONE_COUNT >= 1 && PHONE_COUNT <= 100 )) \
    || die "KFX_PHONE_COUNT muss zwischen 1 und 100 liegen."
  [[ "$FIRST_EXTENSION" =~ ^[0-9]+$ ]] && (( FIRST_EXTENSION >= 100 && FIRST_EXTENSION <= 8999 )) \
    || die "KFX_PHONE_FIRST_EXTENSION ist ungueltig."
  [[ "$PHONE_PORT" =~ ^[0-9]+$ ]] && (( PHONE_PORT >= 1 && PHONE_PORT <= 65535 )) \
    || die "KFX_PHONE_INTERNAL_PORT ist ungueltig."
  [[ "$PHONE_PORT" != "${KFX_SIP_BIND_PORT:-5070}" ]] \
    || die "Interner Telefonie-Port und externer Provider-Port duerfen nicht identisch sein."
  command -v python3 >/dev/null 2>&1 || die "python3 fehlt fuer die Netzpruefung."
  python3 - "$PHONE_BIND_IP" "$PHONE_LOCAL_CIDR" <<'PY'
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
network = ipaddress.ip_network(sys.argv[2], strict=False)
if address.version != 4 or network.version != 4 or address not in network:
    raise SystemExit(1)
PY
  python3 - "$PHONE_ALLOWED_CIDR" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
if network.version != 4:
    raise SystemExit(1)
PY
  [[ "$PHONE_REMOTE_ACCESS_ENABLED" == "y" || "$PHONE_REMOTE_ACCESS_ENABLED" == "n" ]] \
    || die "KFX_PHONE_REMOTE_ACCESS_ENABLED muss y oder n sein."
  if [[ "$PHONE_REMOTE_ACCESS_ENABLED" != "y" && "$PHONE_ALLOWED_CIDR" != "$PHONE_LOCAL_CIDR" ]]; then
    die "Ohne externe SIP-Erreichbarkeit muss KFX_PHONE_ALLOWED_CIDR dem internen Netz entsprechen."
  fi
  command -v ip >/dev/null 2>&1 || die "ip aus iproute2 fehlt."
  ip -o -4 addr show | awk -v ip="$PHONE_BIND_IP" '{split($4, a, "/"); if (a[1] == ip) found=1} END {exit found ? 0 : 1}' \
    || die "Interne Bind-IP ${PHONE_BIND_IP} ist auf diesem System nicht aktiv. Optionen bitte neu setzen."
  [[ "${KFX_PHONE_IN_SIP_NUMBER:-}" =~ ^[0-9]+$ ]] \
    || die "KFX_PHONE_IN_SIP_NUMBER fehlt oder ist ungueltig."
  [[ "${KFX_PHONE_IN_SIP_NUMBER}" != "${KFX_FAX_DID:-}" ]] \
    || die "Telefonie-DID und Fax-DID muessen verschieden sein."
  local capacity_value
  for capacity_value in "$PROVIDER_CHANNEL_LIMIT" "$PROVIDER_PHONE_LIMIT" "$QUEUE_MAX_WAITING" "$SIPGATE_OVERFLOW_CHANNEL_LIMIT"; do
    [[ "$capacity_value" =~ ^[1-9][0-9]*$ ]] || die "Alle Kanal- und Queuegrenzen muessen positive Ganzzahlen sein."
  done
  if [[ "$QUEUE_ONLY" != "y" ]]; then
    [[ "$PROVIDER_FAX_LIMIT" =~ ^[1-9][0-9]*$ ]] || die "Die Fax-Kanalgrenze muss eine positive Ganzzahl sein."
  fi
  (( PROVIDER_PHONE_LIMIT <= PROVIDER_CHANNEL_LIMIT )) \
    || die "Telefonie-Teilgrenze darf die Gesamtgrenze nicht ueberschreiten."
  (( PROVIDER_FAX_LIMIT <= PROVIDER_CHANNEL_LIMIT )) \
    || die "Fax-Teilgrenze darf die Gesamtgrenze nicht ueberschreiten."
  [[ "$PHONE_OUT_COUNTS_PROVIDER_LIMIT" == "y" || "$PHONE_OUT_COUNTS_PROVIDER_LIMIT" == "n" ]] \
    || die "KFX_PHONE_OUT_COUNTS_PROVIDER_LIMIT muss y oder n sein."

  if [[ "$SIPGATE_OVERFLOW_ENABLED" == "y" ]]; then
    [[ "${KFX_SIPGATE_OVERFLOW_SIP_ID:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Sipgate-Ueberlauf-SIP-ID ist ungueltig."
    [[ -n "${KFX_SIPGATE_OVERFLOW_SIP_PASSWORD:-}" ]] || die "Sipgate-Ueberlauf-Passwort fehlt."
    [[ "${KFX_SIPGATE_OVERFLOW_DID:-}" =~ ^[0-9]+$ ]] || die "Sipgate-Ueberlauf-DID ist ungueltig."
    [[ "$SIPGATE_OVERFLOW_DOMAIN" == "sipconnect.sipgate.de" ]] \
      || die "Sipgate-Ueberlauf muss sipconnect.sipgate.de verwenden."
  fi

  local index ext secret_var secret
  for (( index=0; index<PHONE_COUNT; index++ )); do
    ext=$((FIRST_EXTENSION + index))
    secret_var="KFX_PHONE_ENDPOINT_${ext}_PASSWORD"
    secret="$(env_value "$secret_var")"
    [[ -n "$secret" ]] || die "Lokales PJSIP-Passwort fuer Nebenstelle ${ext} fehlt. Optionen bitte neu setzen."
  done
}

append_sipgate_overflow(){
  local sip_id password_cfg did
  sip_id="${KFX_SIPGATE_OVERFLOW_SIP_ID}"
  password_cfg="$(ast_cfg_value "${KFX_SIPGATE_OVERFLOW_SIP_PASSWORD}")"
  did="${KFX_SIPGATE_OVERFLOW_DID}"

  cat >>"$PJSIP_TMP" <<EOF

; sipgate trunking: additiver Eingang fuer Ueberlauf-Telefonie
[kfx-sipgate-overflow-registration]
type=registration
transport=transport-udp
outbound_auth=kfx-sipgate-overflow-auth
server_uri=sip:${sip_id}@${SIPGATE_OVERFLOW_DOMAIN}
client_uri=sip:${sip_id}@${SIPGATE_OVERFLOW_DOMAIN}
contact_user=inbound-calls
retry_interval=60
forbidden_retry_interval=600
expiration=600
line=yes
endpoint=kfx-sipgate-overflow-endpoint

[kfx-sipgate-overflow-auth]
type=auth
auth_type=userpass
username=${sip_id}
password=${password_cfg}

[kfx-sipgate-overflow-aor]
type=aor
contact=sip:${SIPGATE_OVERFLOW_DOMAIN}

[kfx-sipgate-overflow-endpoint]
type=endpoint
transport=transport-udp
context=kfx-phone-overflow-provider
disallow=all
allow=g722,alaw,ulaw
outbound_auth=kfx-sipgate-overflow-auth
aors=kfx-sipgate-overflow-aor
direct_media=no
rewrite_contact=yes
rtp_symmetric=yes
force_rport=yes
from_user=${sip_id}
from_domain=${SIPGATE_OVERFLOW_DOMAIN}
send_pai=yes
send_rpid=yes
trust_id_inbound=yes

[kfx-sipgate-overflow-identify]
type=identify
endpoint=kfx-sipgate-overflow-endpoint
match=${SIPGATE_OVERFLOW_DOMAIN}
match=${SIPGATE_OVERFLOW_IDENTIFY_MATCH}
EOF
}

append_provider(){
  local role="$1" object_prefix="$2" endpoint="$3"
  local prefix="KFX_PHONE_${role}" provider user password domain proxy identify expiration endpoint_context="kfx-provider-in"
  local provider_transport="transport-udp" server_uri="" aor_contact="" endpoint_media_security=""
  if [[ "$QUEUE_ONLY" == "y" ]]; then
    endpoint_context="kfx-phone-in"
  fi
  provider="$(env_value "${prefix}_PROVIDER")"
  user="$(env_value "${prefix}_SIP_USER")"
  password="$(env_value "${prefix}_SIP_PASSWORD")"
  domain="$(env_value "${prefix}_SIP_DOMAIN")"
  proxy="$(env_value "${prefix}_SIP_OUTBOUND_PROXY")"
  identify="$(env_value "${prefix}_SIP_IDENTIFY_MATCH")"
  expiration="$(env_value "${prefix}_SIP_EXPIRATION")"

  if [[ "$provider" == "manual" ]]; then
    {
      echo
      echo "; ${role}: Provider manuell. Erwarteter Endpoint: ${endpoint}"
      echo "; Eingehende Provider-Endpunkte muessen context=kfx-provider-in verwenden."
    } >>"$PJSIP_TMP"
    return 0
  fi

  if [[ "$provider" == "1und1-tls" ]]; then
    provider_transport="transport-1und1-tls"
    server_uri='sip:tls-sip.1und1.de:5061\;transport=tls'
    aor_contact='sip:tls-sip.1und1.de:5061\;transport=tls'
    endpoint_media_security=$'media_encryption=sdes\nmedia_encryption_optimistic=no'
  else
    server_uri="sip:${domain}"
    aor_contact="sip:${domain}"
  fi

  [[ -n "$user" && -n "$password" && -n "$domain" ]] \
    || die "Providerdaten fuer Telefonie-${role} sind unvollstaendig."
  [[ "$expiration" =~ ^[0-9]+$ ]] || die "Ungueltige Registration Expiration fuer Telefonie-${role}."

  local password_cfg proxy_line=""
  password_cfg="$(ast_cfg_value "$password")"
  if [[ -n "$proxy" ]]; then
    if [[ "$proxy" == sip:* ]]; then
      proxy_line="outbound_proxy=${proxy}\\;lr"
    else
      proxy_line="outbound_proxy=sip:${proxy}\\;lr"
    fi
  fi

  cat >>"$PJSIP_TMP" <<EOF

[${object_prefix}-registration]
type=registration
transport=${provider_transport}
outbound_auth=${object_prefix}-auth
server_uri=${server_uri}
client_uri=sip:${user}@${domain}
contact_user=${user}
retry_interval=60
forbidden_retry_interval=600
expiration=${expiration}
${proxy_line}

[${object_prefix}-auth]
type=auth
auth_type=userpass
username=${user}
password=${password_cfg}

[${object_prefix}-aor]
type=aor
contact=${aor_contact}

[${endpoint}]
type=endpoint
transport=${provider_transport}
context=${endpoint_context}
disallow=all
allow=g722,alaw,ulaw
${endpoint_media_security}
outbound_auth=${object_prefix}-auth
aors=${object_prefix}-aor
direct_media=no
rewrite_contact=yes
rtp_symmetric=yes
force_rport=yes
t38_udptl=no
t38_udptl_nat=no
from_user=${user}
from_domain=${domain}
send_pai=yes
send_rpid=yes
trust_id_outbound=yes
${proxy_line}
EOF

  if [[ -n "$identify" ]]; then
    cat >>"$PJSIP_TMP" <<EOF

[${object_prefix}-identify]
type=identify
endpoint=${endpoint}
match=${identify}
EOF
  fi
}

copy_german_prompts(){
  local source_dir="$GERMAN_SOUND_SOURCE" data_dir="" target_dir="" owner="root:root"
  [[ -d "$source_dir" ]] || die "Deutsche Asterisk-Ansagen fehlen: Paket asterisk-prompt-de pruefen."
  data_dir="$(asterisk -rx "core show settings" 2>/dev/null | awk -F: '/Data directory/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  [[ -n "$data_dir" ]] || data_dir="/var/lib/asterisk"
  target_dir="${data_dir}/sounds/de"
  install -d -m 0755 "$target_dir"
  cp -a "${source_dir}/." "${target_dir}/"
  if id asterisk >/dev/null 2>&1; then owner="asterisk:asterisk"; fi
  chown -R "$owner" "$target_dir" 2>/dev/null || true
  find "$target_dir" -type d -exec chmod 0755 {} +
  find "$target_dir" -type f -exec chmod 0644 {} +

  local required
  for required in \
    queue-thankyou.gsm queue-youarenext.gsm queue-thereare.gsm queue-callswaiting.gsm; do
    [[ -s "${target_dir}/${required}" ]] || die "Erforderliche deutsche Queue-Ansage fehlt: ${target_dir}/${required}"
  done
  log "[OK] Deutsche Queue-Ansagen geprueft: ${target_dir}"
}

PJSIP_TMP="$(mktemp)"
EXTENSIONS_TMP="$(mktemp)"
QUEUES_TMP="$(mktemp)"
QUEUE_RULES_TMP="$(mktemp)"
trap 'rm -f "$PJSIP_TMP" "$EXTENSIONS_TMP" "$QUEUES_TMP" "$QUEUE_RULES_TMP"' EXIT

if [[ "$PHONE_ENABLED" == "y" ]]; then
  validate_phone_settings
  copy_german_prompts

  cat >"$PJSIP_TMP" <<EOF
; generated by kienzlefax telefonie-queue.sh

[transport-kfx-phone]
type=transport
protocol=udp
bind=${PHONE_BIND_IP}:${PHONE_PORT}
local_net=${PHONE_LOCAL_CIDR}
EOF

  for (( index=0; index<PHONE_COUNT; index++ )); do
    ext=$((FIRST_EXTENSION + index))
    secret_var="KFX_PHONE_ENDPOINT_${ext}_PASSWORD"
    secret="$(env_value "$secret_var")"
    secret_cfg="$(ast_cfg_value "$secret")"
    cat >>"$PJSIP_TMP" <<EOF

[${ext}-auth]
type=auth
auth_type=userpass
username=${ext}
password=${secret_cfg}

[${ext}]
type=aor
max_contacts=1
remove_existing=yes
qualify_frequency=30

[${ext}]
type=endpoint
transport=transport-kfx-phone
context=kfx-phone-local
disallow=all
allow=g722,alaw,ulaw
auth=${ext}-auth
aors=${ext}
callerid=Empfang $((index + 1)) <${ext}>
direct_media=no
rewrite_contact=yes
rtp_symmetric=yes
force_rport=yes
device_state_busy_at=1
EOF
    if [[ "$PHONE_ALLOWED_CIDR" == "0.0.0.0/0" ]]; then
      cat >>"$PJSIP_TMP" <<EOF
; Keine PJSIP-ACL: SIP-Nebenstellen sind aus allen IPv4-Netzen erlaubt.
; Der Installer richtet bewusst keine Firewallregeln ein; Schutz ist Betreiberaufgabe.
EOF
    else
      cat >>"$PJSIP_TMP" <<EOF
deny=0.0.0.0/0.0.0.0
permit=${PHONE_ALLOWED_CIDR}
contact_deny=0.0.0.0/0.0.0.0
contact_permit=${PHONE_ALLOWED_CIDR}
EOF
    fi
  done

  append_provider IN "kfx-phone-in" "kfx-phone-in-endpoint"
  OUT_ENDPOINT="kfx-phone-in-endpoint"
  if [[ "${KFX_PHONE_SEPARATE_OUTBOUND:-n}" == "y" ]]; then
    append_provider OUT "kfx-phone-out" "kfx-phone-out-endpoint"
    OUT_ENDPOINT="kfx-phone-out-endpoint"
  fi
  if [[ "$SIPGATE_OVERFLOW_ENABLED" == "y" ]]; then
    append_sipgate_overflow
  fi

  cat >"$EXTENSIONS_TMP" <<'EOF'
; generated by kienzlefax telefonie-queue.sh

[kfx-phone-in]
exten => _X.,1,Goto(s,1)
exten => _+X.,1,Goto(s,1)
exten => inbound-calls,1,Goto(s,1)
exten => s,1,NoOp(KienzleFax Telefonieeingang Hauptprovider)
 same => n,Gosub(kfx_external_capacity,primary-phone,1)
 same => n,GotoIf($["${KFX_CAPACITY_OK}"="1"]?accepted)
 same => n,NoOp(KFX PHONE rejected before answer: primary provider capacity full)
 same => n,Hangup(17)
 same => n(accepted),Goto(kfx-phone-queue,s,1)

[kfx-phone-overflow-provider]
exten => __KFX_SIPGATE_OVERFLOW_DID__,1,Goto(kfx-phone-overflow-in,s,1)
exten => _+X.,1,Goto(kfx-phone-overflow-in,s,1)
exten => inbound-calls,1,Goto(kfx-phone-overflow-in,s,1)

[kfx-phone-overflow-in]
exten => s,1,NoOp(KienzleFax Telefonieeingang Sipgate-Ueberlauf)
 same => n,Gosub(kfx_external_capacity,sipgate-phone,1)
 same => n,GotoIf($["${KFX_CAPACITY_OK}"="1"]?accepted)
 same => n,NoOp(KFX PHONE rejected before answer: sipgate overflow capacity full)
 same => n,Hangup(17)
 same => n(accepted),Goto(kfx-phone-queue,s,1)

[kfx-phone-queue]
exten => s,1,NoOp(KienzleFax Telefoniewarteschlange)
 same => n,Set(CHANNEL(language)=de)
 same => n,Set(KFX_QUEUE_WAITING=${QUEUE_WAITING_COUNT(praxis)})
 same => n,GotoIf($[${KFX_QUEUE_WAITING} >= __KFX_QUEUE_MAX_WAITING__]?full)
 same => n,Answer()
 same => n,Set(QUEUE_RAISE_PENALTY=0)
 same => n,Queue(praxis,r)
 same => n,GotoIf($["${QUEUESTATUS}"="FULL"]?full)
 same => n,Hangup()
 same => n(full),NoOp(KFX PHONE rejected before answer: queue maxlen reached)
 same => n,Hangup(17)

[kfx-phone-local]
__KFX_LOCAL_PHONE_ROUTES__

exten => _X.,1,NoOp(KienzleFax Telefonie ausgehend)
 same => n,GotoIf($["__KFX_PHONE_OUT_COUNTS_PROVIDER_LIMIT__"!="y"]?dial)
 same => n,Gosub(kfx_external_capacity,primary-phone,1)
 same => n,GotoIf($["${KFX_CAPACITY_OK}"="1"]?dial)
 same => n,NoOp(KFX PHONE outgoing rejected: primary provider capacity full)
 same => n,Hangup(17)
 same => n(dial),Set(CALLERID(num)=__KFX_PHONE_OUT_NUMBER__)
 same => n,Dial(PJSIP/${EXTEN}@__KFX_PHONE_OUT_ENDPOINT__,120)
 same => n,Hangup()
EOF

  python3 - "$EXTENSIONS_TMP" "$FIRST_EXTENSION" "$PHONE_COUNT" "$OUT_ENDPOINT" "${KFX_PHONE_OUT_SIP_NUMBER:-}" "$PHONE_OUT_COUNTS_PROVIDER_LIMIT" "$SIPGATE_OVERFLOW_ENABLED" "${KFX_SIPGATE_OVERFLOW_DID:-}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
first = int(sys.argv[2])
count = int(sys.argv[3])
endpoint = sys.argv[4]
callerid = sys.argv[5]
out_counts = sys.argv[6]
overflow_enabled = sys.argv[7] == "y"
overflow_did = sys.argv[8]
routes = []
for extension in range(first, first + count):
    routes.extend([
        f"exten => {extension},1,NoOp(Interner Anruf zu Empfang {extension})",
        f" same => n,Set(KFX_INTERNAL_TARGET_STATE=${{DEVICE_STATE(PJSIP/{extension})}})",
        ' same => n,GotoIf($["${KFX_INTERNAL_TARGET_STATE}"="NOT_INUSE"]?dial:busy)',
        f" same => n(dial),Dial(PJSIP/{extension},120)",
        " same => n,Hangup()",
        f" same => n(busy),NoOp(Interner Anruf zu Empfang {extension} abgewiesen: ${{KFX_INTERNAL_TARGET_STATE}})",
        " same => n,Hangup(17)",
        "",
    ])
text = path.read_text(encoding="utf-8")
text = text.replace("__KFX_LOCAL_PHONE_ROUTES__", "\n".join(routes).rstrip())
text = text.replace("__KFX_PHONE_OUT_ENDPOINT__", endpoint)
text = text.replace("__KFX_PHONE_OUT_NUMBER__", callerid)
text = text.replace("__KFX_PHONE_OUT_COUNTS_PROVIDER_LIMIT__", out_counts)
if overflow_enabled:
    text = text.replace("__KFX_SIPGATE_OVERFLOW_DID__", overflow_did)
else:
    start = text.index("[kfx-phone-overflow-provider]")
    end = text.index("[kfx-phone-queue]")
    text = text[:start] + "; Sipgate-Ueberlauf deaktiviert.\n\n" + text[end:]
path.write_text(text, encoding="utf-8")
PY
  sed -i "s/__KFX_QUEUE_MAX_WAITING__/${QUEUE_MAX_WAITING}/g" "$EXTENSIONS_TMP"

  if [[ "$QUEUE_ONLY" == "y" ]]; then
    CAPACITY_TMP="$(mktemp)"
    cat >"$CAPACITY_TMP" <<'EOF'
; Queue-only capacity guard. Faxgruppen und Fax-Nebenstellen existieren bewusst nicht.
[kfx_external_capacity]
exten => primary-phone,1,NoOp(KFX CAPACITY request=primary-phone chan=${CHANNEL(name)})
 same => n,Set(KFX_CAPACITY_OK=0)
 same => n,GotoIf($["${GROUP(kfx_primary_total)}"="active" & "${GROUP(kfx_primary_phone)}"="active"]?already_reserved)
 same => n,Set(KFX_CAPACITY_LOCK=${LOCK(kfx_external_capacity_lock)})
 same => n,GotoIf($["${KFX_CAPACITY_LOCK}"="1"]?locked:lock_failed)
 same => n(locked),Set(KFX_PRIMARY_TOTAL_COUNT=${GROUP_COUNT(active@kfx_primary_total)})
 same => n,Set(KFX_PRIMARY_PHONE_COUNT=${GROUP_COUNT(active@kfx_primary_phone)})
 same => n,GotoIf($[${KFX_PRIMARY_TOTAL_COUNT} >= __KFX_PROVIDER_CHANNEL_LIMIT__]?full)
 same => n,GotoIf($[${KFX_PRIMARY_PHONE_COUNT} >= __KFX_PROVIDER_PHONE_LIMIT__]?full)
 same => n,Set(GROUP(kfx_primary_total)=active)
 same => n,Set(GROUP(kfx_primary_phone)=active)
 same => n,Set(KFX_CAPACITY_OK=1)
 same => n,Set(KFX_CAPACITY_UNLOCK=${UNLOCK(kfx_external_capacity_lock)})
 same => n,Return()
 same => n(full),Set(KFX_CAPACITY_UNLOCK=${UNLOCK(kfx_external_capacity_lock)})
 same => n,Return()
 same => n(already_reserved),Set(KFX_CAPACITY_OK=1)
 same => n,Return()
 same => n(lock_failed),NoOp(KFX CAPACITY lock failed primary-phone - fail closed)
 same => n,Return()

exten => sipgate-phone,1,NoOp(KFX CAPACITY request=sipgate-phone chan=${CHANNEL(name)})
 same => n,Set(KFX_CAPACITY_OK=0)
 same => n,GotoIf($["${GROUP(kfx_sipgate_overflow)}"="active"]?already_reserved)
 same => n,Set(KFX_CAPACITY_LOCK=${LOCK(kfx_external_capacity_lock)})
 same => n,GotoIf($["${KFX_CAPACITY_LOCK}"="1"]?locked:lock_failed)
 same => n(locked),Set(KFX_SIPGATE_COUNT=${GROUP_COUNT(active@kfx_sipgate_overflow)})
 same => n,GotoIf($[${KFX_SIPGATE_COUNT} >= __KFX_SIPGATE_OVERFLOW_CHANNEL_LIMIT__]?full)
 same => n,Set(GROUP(kfx_sipgate_overflow)=active)
 same => n,Set(KFX_CAPACITY_OK=1)
 same => n,Set(KFX_CAPACITY_UNLOCK=${UNLOCK(kfx_external_capacity_lock)})
 same => n,Return()
 same => n(full),Set(KFX_CAPACITY_UNLOCK=${UNLOCK(kfx_external_capacity_lock)})
 same => n,Return()
 same => n(already_reserved),Set(KFX_CAPACITY_OK=1)
 same => n,Return()
 same => n(lock_failed),NoOp(KFX CAPACITY lock failed sipgate-phone - fail closed)
 same => n,Return()

EOF
    sed -i "s/__KFX_PROVIDER_CHANNEL_LIMIT__/${PROVIDER_CHANNEL_LIMIT}/g" "$CAPACITY_TMP"
    sed -i "s/__KFX_PROVIDER_PHONE_LIMIT__/${PROVIDER_PHONE_LIMIT}/g" "$CAPACITY_TMP"
    sed -i "s/__KFX_SIPGATE_OVERFLOW_CHANNEL_LIMIT__/${SIPGATE_OVERFLOW_CHANNEL_LIMIT}/g" "$CAPACITY_TMP"
    COMBINED_TMP="$(mktemp)"
    { cat "$CAPACITY_TMP"; cat "$EXTENSIONS_TMP"; } >"$COMBINED_TMP"
    mv -f "$COMBINED_TMP" "$EXTENSIONS_TMP"
    rm -f "$CAPACITY_TMP"
  fi

  cat >"$QUEUES_TMP" <<'EOF'
; generated by kienzlefax telefonie-queue.sh

[praxis]
strategy=ringall
autofill=yes
ringinuse=no
joinempty=yes
leavewhenempty=no
; 19 Sekunden Rufversuch + 1 Sekunde Retry = naechste Prioritaetsstufe nach 20 Sekunden
timeout=19
retry=1
defaultrule=kfx-phone-progressive
; Warteposition sofort beim Eintritt und danach hoechstens einmal pro Minute ansagen.
announce-position=yes
announce-frequency=60
min-announce-frequency=60
announce-to-first-user=yes
announce-holdtime=no
maxlen=__KFX_QUEUE_MAX_WAITING__
EOF

  sed -i "s/__KFX_QUEUE_MAX_WAITING__/${QUEUE_MAX_WAITING}/g" "$QUEUES_TMP"

  for (( index=0; index<PHONE_COUNT; index++ )); do
    ext=$((FIRST_EXTENSION + index))
    printf 'member => PJSIP/%s,%s,Empfang %s,PJSIP/%s,no\n' "$ext" "$index" "$((index + 1))" "$ext" >>"$QUEUES_TMP"
  done

  cat >"$QUEUE_RULES_TMP" <<'EOF'
; generated by kienzlefax telefonie-queue.sh

[kfx-phone-progressive]
EOF
  for (( index=1; index<PHONE_COUNT; index++ )); do
    printf 'penaltychange => %s,,,%s\n' "$((index * 20))" "$index" >>"$QUEUE_RULES_TMP"
  done
else
  printf '; Telefoniewarteschlange ist deaktiviert.\n' >"$PJSIP_TMP"
  printf '; Telefoniewarteschlange ist deaktiviert.\n' >"$EXTENSIONS_TMP"
  printf '; Telefoniewarteschlange ist deaktiviert.\n' >"$QUEUES_TMP"
  printf '; Telefoniewarteschlange ist deaktiviert.\n' >"$QUEUE_RULES_TMP"
fi

PJSIP_RESTART_REQUIRED="n"
if [[ "$PHONE_ENABLED" == "y" ]]; then
  if [[ ! -f "$PJSIP_PHONE" ]] || ! cmp -s "$PJSIP_TMP" "$PJSIP_PHONE"; then
    PJSIP_RESTART_REQUIRED="y"
  fi
  if ! grep -Fxq "$PJSIP_INCLUDE" "$PJSIP_MAIN" 2>/dev/null; then
    PJSIP_RESTART_REQUIRED="y"
  fi
  if ! asterisk -rx "pjsip show transport transport-kfx-phone" >/dev/null 2>&1; then
    PJSIP_RESTART_REQUIRED="y"
  fi
  if ! phone_transport_listening; then
    PJSIP_RESTART_REQUIRED="y"
  fi
elif [[ -f "$PJSIP_PHONE" ]] && grep -q '^\[transport-kfx-phone\]' "$PJSIP_PHONE"; then
  PJSIP_RESTART_REQUIRED="y"
fi

if [[ "$PJSIP_RESTART_REQUIRED" == "y" ]]; then
  ACTIVE_CHANNELS="$(active_channel_count)"
  [[ "$ACTIVE_CHANNELS" =~ ^[0-9]+$ ]] || ACTIVE_CHANNELS=0
  (( ACTIVE_CHANNELS == 0 )) \
    || die "Asterisk-Neustart fuer den internen SIP-Transport noetig, aber ${ACTIVE_CHANNELS} Kanaele sind aktiv. Spaeter erneut ausfuehren."
fi

sep "Telefonie-Konfigurationsdateien"
install_generated_file "$PJSIP_TMP" "$PJSIP_PHONE" 0640 || true
install_generated_file "$EXTENSIONS_TMP" "$EXTENSIONS_PHONE" 0640 || true
install_generated_file "$QUEUES_TMP" "$QUEUES_PHONE" 0640 || true
install_generated_file "$QUEUE_RULES_TMP" "$QUEUE_RULES_PHONE" 0640 || true

grep -Fxq "$PJSIP_INCLUDE" "$PJSIP_MAIN" \
  || die "Telefonie-Include fehlt in ${PJSIP_MAIN}; pjsip-provider.sh zuerst ausfuehren."
grep -Fxq "$EXTENSIONS_INCLUDE" "$EXTENSIONS_MAIN" \
  || die "Telefonie-Include fehlt in ${EXTENSIONS_MAIN}; extensions.sh zuerst ausfuehren."
ensure_include "$QUEUES_MAIN" "$QUEUES_INCLUDE" || true
ensure_include "$QUEUE_RULES_MAIN" "$QUEUE_RULES_INCLUDE" || true
chmod 0640 "$PJSIP_MAIN" "$PJSIP_PHONE" "$EXTENSIONS_MAIN" "$EXTENSIONS_PHONE" "$QUEUES_PHONE" "$QUEUE_RULES_PHONE" 2>/dev/null || true

if [[ "$PJSIP_RESTART_REQUIRED" == "y" ]]; then
  sep "Asterisk kontrolliert neu starten (PJSIP-Transportaenderung)"
  systemctl restart asterisk
  wait_for_asterisk_cli 90 || die "Asterisk CLI ist nach dem Neustart nicht bereit."
else
  asterisk -rx "pjsip reload" || true
fi

if [[ "$PHONE_ENABLED" == "y" ]] && ! phone_transport_listening; then
  die "Interner PJSIP-Transport ist konfiguriert, aber Asterisk lauscht nicht auf ${PHONE_BIND_IP}:${PHONE_PORT}/UDP."
fi

asterisk -rx "dialplan reload" || true

if [[ "$PHONE_ENABLED" == "y" ]]; then
  asterisk -rx "module load app_queue.so" >/dev/null 2>&1 || true
  asterisk -rx "module load res_musiconhold.so" >/dev/null 2>&1 || true
  QUEUE_MODULE="$(asterisk -rx "module show like app_queue" 2>/dev/null || true)"
  MOH_MODULE="$(asterisk -rx "module show like res_musiconhold" 2>/dev/null || true)"
  [[ "$QUEUE_MODULE" == *"app_queue.so"* && "$QUEUE_MODULE" == *"Running"* ]] \
    || die "app_queue.so ist nicht geladen."
  [[ "$MOH_MODULE" == *"res_musiconhold.so"* && "$MOH_MODULE" == *"Running"* ]] \
    || die "res_musiconhold.so ist nicht geladen."
  asterisk -rx "module reload app_queue.so" || true
  asterisk -rx "pjsip send register kfx-phone-in-registration" >/dev/null 2>&1 || true
  if [[ "${KFX_PHONE_SEPARATE_OUTBOUND:-n}" == "y" ]]; then
    asterisk -rx "pjsip send register kfx-phone-out-registration" >/dev/null 2>&1 || true
  fi
  if [[ "$SIPGATE_OVERFLOW_ENABLED" == "y" ]]; then
    asterisk -rx "pjsip send register kfx-sipgate-overflow-registration" >/dev/null 2>&1 || true
  fi
  echo "[OK] Telefoniewarteschlange aktiv."
  echo "[INFO] Interne SIP-Schnittstelle: ${KFX_PHONE_BIND_IFACE:-unbekannt}"
  echo "[INFO] Interner SIP-Registrar: ${PHONE_BIND_IP}:${PHONE_PORT}"
  echo "[INFO] Zulaessiges internes SIP-Netz: ${PHONE_LOCAL_CIDR}"
  if [[ "$PHONE_REMOTE_ACCESS_ENABLED" == "y" ]]; then
    echo "[WARN] SIP-Nebenstellen aus anderen Netzen/Internet erlaubt; Quellnetz: ${PHONE_ALLOWED_CIDR}."
  else
    echo "[INFO] SIP-Nebenstellen nur aus dem internen Netz erlaubt."
  fi
  echo "[INFO] Nebenstellen: ${FIRST_EXTENSION}-$((FIRST_EXTENSION + PHONE_COUNT - 1))"
  echo "[INFO] Wartesignal: Klingelzeichen; deutsche Positionsansage sofort beim Eintritt und danach minuetlich."
  echo "[INFO] Grenzen Hauptleitung: ${PROVIDER_CHANNEL_LIMIT} insgesamt, ${PROVIDER_PHONE_LIMIT} Telefonie, ${PROVIDER_FAX_LIMIT} Fax."
  echo "[INFO] Warteschlange: maximal ${QUEUE_MAX_WAITING} wartende Anrufer."
  if [[ "$SIPGATE_OVERFLOW_ENABLED" == "y" ]]; then
    echo "[WARN] Sipgate-Ueberlauf: EXPERIMENTELL aktiv, separate additive Grenze ${SIPGATE_OVERFLOW_CHANNEL_LIMIT}."
  fi
  echo "[INFO] Ueberlast wird vor Annahme mit SIP Busy abgewiesen; netzseitigen Busy-Steuercode beim Provider pruefen."
  echo "[INFO] Keine Firewallregeln wurden eingerichtet."
  asterisk -rx "queue show praxis" || true
else
  echo "[OK] Telefoniewarteschlange deaktiviert."
fi

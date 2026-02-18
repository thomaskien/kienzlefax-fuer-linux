#!/usr/bin/env bash
set -euo pipefail

ENVFILE="/etc/kienzlefax-installer.env"
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
fi

# ---- resolve variables (support both KFX_* and legacy names) ----
# Required:
PJSIP_USER="${PJSIP_USER:-${KFX_SIP_NUMBER:-}}"
PJSIP_PASS="${PJSIP_PASS:-${KFX_SIP_PASSWORD:-}}"
SIP_BIND_PORT="${SIP_BIND_PORT:-${PJSIP_PORT:-${PJSIP_BIND_PORT:-${KFX_SIP_BIND_PORT:-5070}}}}"

# Optional:
PJSIP_OUTBOUND_PROXY="${PJSIP_OUTBOUND_PROXY:-}"
PUBLIC_FQDN="${PUBLIC_FQDN:-${KFX_PUBLIC_FQDN:-}}"

# Derived / defaults for 1und1:
PROVIDER_DOMAIN="sip.1und1.de"
SERVER_URI="sip:${PROVIDER_DOMAIN}"

# client_uri: if caller provided something use it, else build it.
PJSIP_CLIENT_URI="${PJSIP_CLIENT_URI:-}"
if [ -z "${PJSIP_CLIENT_URI}" ]; then
  # typical: sip:<user>@sip.1und1.de
  PJSIP_CLIENT_URI="sip:${PJSIP_USER}@${PROVIDER_DOMAIN}"
fi

# validate required
if [ -z "${PJSIP_USER}" ] || [ -z "${PJSIP_PASS}" ]; then
  echo "ERROR: PJSIP_USER/PJSIP_PASS fehlen. (KFX_SIP_NUMBER/KFX_SIP_PASSWORD oder PJSIP_USER/PJSIP_PASS setzen)" >&2
  exit 1
fi
if ! [[ "${SIP_BIND_PORT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SIP_BIND_PORT ungültig: '${SIP_BIND_PORT}'" >&2
  exit 1
fi

PJSIP="/etc/asterisk/pjsip.conf"
cp -a "$PJSIP" "${PJSIP}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

# outbound proxy line (optional)
OUTBOUND_PROXY_LINE=""
if [ -n "${PJSIP_OUTBOUND_PROXY}" ]; then
  # ensure it has sip:
  if [[ "${PJSIP_OUTBOUND_PROXY}" =~ ^sip: ]]; then
    OUTBOUND_PROXY_LINE="outbound_proxy=${PJSIP_OUTBOUND_PROXY}\;lr"
  else
    OUTBOUND_PROXY_LINE="outbound_proxy=sip:${PJSIP_OUTBOUND_PROXY}\;lr"
  fi
fi

cat >"$PJSIP" <<EOF
; ===== KienzleFax / 1und1 Provider (auto-generated) =====
; Hinweis: Für andere Provider hier anpassen.
; Generated: $(date -Is)

; --- Transport: bind to 0.0.0.0:${SIP_BIND_PORT} ---
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:${SIP_BIND_PORT}

; --- Auth ---
[1und1-auth]
type=auth
auth_type=userpass
username=${PJSIP_USER}
password=${PJSIP_PASS}

; --- AOR ---
[1und1-aor]
type=aor
contact=sip:${PROVIDER_DOMAIN}

; --- Endpoint ---
[1und1-endpoint]
type=endpoint
transport=transport-udp
context=fax-in
disallow=all
allow=alaw,ulaw
aors=1und1-aor
auth=1und1-auth
from_domain=${PROVIDER_DOMAIN}
direct_media=no
force_rport=yes
rewrite_contact=yes
rtp_symmetric=yes
timers=no
${OUTBOUND_PROXY_LINE}

; --- Identify ---
[1und1-identify]
type=identify
endpoint=1und1-endpoint
match=${PROVIDER_DOMAIN}

; --- Registration ---
[1und1-reg]
type=registration
outbound_auth=1und1-auth
server_uri=${SERVER_URI}
client_uri=${PJSIP_CLIENT_URI}
retry_interval=60
forbidden_retry_interval=300
fatal_retry_interval=300
expiration=3600
transport=transport-udp
${OUTBOUND_PROXY_LINE}
EOF

chmod 0640 "$PJSIP" || true
chown root:asterisk "$PJSIP" 2>/dev/null || true

echo "[INFO] Wrote: $PJSIP"
echo "[INFO] PJSIP_USER=${PJSIP_USER}"
echo "[INFO] SIP_BIND_PORT=${SIP_BIND_PORT}"
[ -n "${PJSIP_OUTBOUND_PROXY}" ] && echo "[INFO] OUTBOUND_PROXY=${PJSIP_OUTBOUND_PROXY}" || true
[ -n "${PUBLIC_FQDN}" ] && echo "[INFO] PUBLIC_FQDN=${PUBLIC_FQDN}" || true

echo "[INFO] Reloading PJSIP..."
asterisk -rx "pjsip reload" || true
asterisk -rx "pjsip show transports" || true
asterisk -rx "pjsip show registrations" || true

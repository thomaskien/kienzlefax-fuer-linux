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
  if [[ "${PJSIP_OUTBOUND_PROXY}" =~ ^sip: ]]; then
    OUTBOUND_PROXY_LINE="outbound_proxy=${PJSIP_OUTBOUND_PROXY}\;lr"
  else
    OUTBOUND_PROXY_LINE="outbound_proxy=sip:${PJSIP_OUTBOUND_PROXY}\;lr"
  fi
fi

# external address lines (optional)
EXTERNAL_ADDR_LINES=""
if [ -n "${PUBLIC_FQDN}" ]; then
  EXTERNAL_ADDR_LINES=$(
    cat <<EOF
external_signaling_address = ${PUBLIC_FQDN}
external_media_address     = ${PUBLIC_FQDN}
EOF
  )
else
  EXTERNAL_ADDR_LINES=$(
    cat <<'EOF'
;external_signaling_address = <PUBLIC_FQDN>
;external_media_address     = <PUBLIC_FQDN>
EOF
  )
fi

cat >"$PJSIP" <<EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:${SIP_BIND_PORT}

${EXTERNAL_ADDR_LINES}

local_net = 10.0.0.0/8
local_net = 192.168.0.0/16



[1und1]
type=registration
transport=transport-udp
outbound_auth=1und1-auth
server_uri=sip:${PROVIDER_DOMAIN}
client_uri=${PJSIP_CLIENT_URI}
contact_user=${PJSIP_USER}
retry_interval=60
forbidden_retry_interval=600
expiration=300
${OUTBOUND_PROXY_LINE}


[1und1-auth]
type=auth
auth_type=userpass
username=${PJSIP_USER}
password=${PJSIP_PASS}

[1und1-aor]
type=aor
contact=sip:${PROVIDER_DOMAIN}

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
;t38_udptl_ec=no
t38_udptl_nat=no
from_user=${PJSIP_USER}
from_domain=${PROVIDER_DOMAIN}
send_pai=yes
send_rpid=yes
trust_id_outbound=yes
${OUTBOUND_PROXY_LINE}

; ===== JITTERBUFFER (PJSIP/chan_pjsip korrekt) =====
;use_jitterbuffer=yes
;jbimpl=adaptive
;jbmaxsize=400
;jbtargetextra=200


[1und1-identify]
type=identify
endpoint=1und1-endpoint

; erstmal die IPs aus deinem Trace
match=212.227.0.0/16
EOF

chmod 0640 "$PJSIP" || true
chown root:asterisk "$PJSIP" 2>/dev/null || true

echo "[INFO] Wrote: $PJSIP"
echo "[INFO] PJSIP_USER=${PJSIP_USER}"
echo "[INFO] SIP_BIND_PORT=${SIP_BIND_PORT}"
echo "[INFO] PJSIP_MATCH_CIDR=${PJSIP_MATCH_CIDR}"
[ -n "${PJSIP_OUTBOUND_PROXY}" ] && echo "[INFO] OUTBOUND_PROXY=${PJSIP_OUTBOUND_PROXY}" || true
[ -n "${PUBLIC_FQDN}" ] && echo "[INFO] PUBLIC_FQDN=${PUBLIC_FQDN}" || true

echo "[INFO] Reloading PJSIP..."
asterisk -rx "pjsip reload" || true
asterisk -rx "pjsip show transports" || true
asterisk -rx "pjsip show registrations" || true

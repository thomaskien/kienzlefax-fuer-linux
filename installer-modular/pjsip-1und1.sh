#!/usr/bin/env bash
set -euo pipefail

# entweder ENVFILE sourcen…
ENVFILE="/etc/kienzlefax-installer.env"
[ -f "$ENVFILE" ] && source "$ENVFILE"


# Compatibility layer (alte Variablennamen, die pjsip-1und1.sh evtl. erwartet)
export PJSIP_USER="${KFX_SIP_NUMBER}"
export PJSIP_PASS="${KFX_SIP_PASSWORD}"
export PJSIP_NUMBER="${KFX_SIP_NUMBER}"
export PJSIP_PASSWORD="${KFX_SIP_PASSWORD}"
export SIP_USER="${KFX_SIP_NUMBER}"
export SIP_PASSWORD="${KFX_SIP_PASSWORD}"
export PUBLIC_FQDN="${KFX_PUBLIC_FQDN}"
export FAX_DID="${KFX_FAX_DID}"
export SIP_BIND_PORT="${KFX_SIP_BIND_PORT}"
export SIP_PORT="${KFX_SIP_BIND_PORT}"
export PJSIP_BIND_PORT="${KFX_SIP_BIND_PORT}"
export PJSIP_PORT="${KFX_SIP_BIND_PORT}"y



# …oder voraussetzen, dass Variablen bereits exported sind.

PJSIP="/etc/asterisk/pjsip.conf"
cp -a "$PJSIP" "${PJSIP}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

cat >"$PJSIP" <<EOF

; ===== KienzleFax / 1und1 Provider (auto-generated) =====
; Hinweis: Für andere Provider hier anpassen.
; WICHTIG: SIP muss an 0.0.0.0 binden -> siehe [transport-udp]

[1und1-auth]
type=auth
auth_type=userpass
username=${PJSIP_USER}
password=${PJSIP_PASS}

[1und1-aor]
type=aor
contact=sip:sip.1und1.de

[1und1-endpoint]
type=endpoint
transport=transport-udp
context=fax-in
disallow=all
allow=alaw,ulaw
aors=1und1-aor
auth=1und1-auth
from_domain=$sip.1und1.de
direct_media=no
force_rport=yes
rewrite_contact=yes
rtp_symmetric=yes
timers=no

; Optional outbound proxy
EOF

if [ -n "$PJSIP_OUTBOUND_PROXY" ]; then
  # pjsip outbound_proxy syntax: sip:host[:port]\;lr
  # akzeptiert auch ohne sip: (Asterisk ist tolerant), aber wir schreiben sauber.
  ensure_line_in_file "$PJSIP_CONF" "outbound_proxy=sip:${PJSIP_OUTBOUND_PROXY}\;lr"
fi

cat >>"$PJSIP_CONF" <<EOF

[1und1-identify]
type=identify
endpoint=1und1-endpoint
match=sip.1und1.de

[1und1-reg]
type=registration
outbound_auth=1und1-auth
server_uri=sip:sip.1und1.de
client_uri=${PJSIP_CLIENT_URI}
retry_interval=60
forbidden_retry_interval=300
fatal_retry_interval=300
expiration=3600
transport=transport-udp
EOF

# (Optional) wenn outbound proxy gesetzt, auch bei registration verwenden:
if [ -n "$PJSIP_OUTBOUND_PROXY" ]; then
  ensure_line_in_file "$PJSIP_CONF" "outbound_proxy=sip:${PJSIP_OUTBOUND_PROXY}\;lr"
fi

sep "PJSIP Reload"
asterisk -rx "pjsip reload" || true
asterisk -rx "pjsip show transports" || true
asterisk -rx "pjsip show registrations" || true

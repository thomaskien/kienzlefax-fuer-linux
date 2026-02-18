#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# PJSIP Provider (1und1) interaktiv abfragen + pjsip.conf schreiben
# -----------------------------------------------------------------------------
sep "PJSIP (1und1): Provider-Daten interaktiv abfragen"

# Minimal erforderliche Werte
prompt_default PJSIP_USER   "1und1 SIP Username (z.B. 49... oder sip-id)" ""
read -r -s -p "1und1 SIP Passwort (wird NICHT angezeigt): " PJSIP_PASS; echo
prompt_default PJSIP_SERVER "1und1 Registrar/Server (z.B. sip.1und1.de)" "sip.1und1.de"

# Optional, aber oft nötig/sauber
prompt_default PJSIP_FROMDOMAIN "From-Domain (leer=wie Server)" ""
prompt_default PJSIP_OUTBOUND_PROXY "Outbound Proxy (leer=keiner, sonst host:port oder host)" ""
prompt_default PJSIP_CLIENT_URI "Client-URI (leer=aus User+Server)" ""

# Ableitungen
PJSIP_FROMDOMAIN="${PJSIP_FROMDOMAIN:-$PJSIP_SERVER}"
PJSIP_CLIENT_URI="${PJSIP_CLIENT_URI:-sip:${PJSIP_USER}@${PJSIP_SERVER}}"

if [ -z "$PJSIP_USER" ] || [ -z "$PJSIP_PASS" ]; then
  die "PJSIP_USER/PJSIP_PASS dürfen nicht leer sein."
fi

backup_file "$PJSIP_CONF"
touch "$PJSIP_CONF"

# Transport sicherstellen (bind an 0.0.0.0, wie du willst)
if ! grep -qE '^\s*\[transport-udp\]\s*$' "$PJSIP_CONF"; then
  cat >>"$PJSIP_CONF" <<EOF

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:${SIP_PORT}
EOF
else
  ini_set_kv "$PJSIP_CONF" "transport-udp" "type" "transport"
  ini_set_kv "$PJSIP_CONF" "transport-udp" "protocol" "udp"
  ini_set_kv "$PJSIP_CONF" "transport-udp" "bind" "0.0.0.0:${SIP_PORT}"
fi

# Provider-Block: ich schreibe ihn als zusammenhängenden Block ans Ende,
# damit wir bestehende 1und1-Konfig nicht "kaputtsedden".
# Wenn du willst, kann ich später auch "replace if exists" machen – aber robust ist append+klarer Marker.
cat >>"$PJSIP_CONF" <<EOF

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
contact=sip:${PJSIP_SERVER}

[1und1-endpoint]
type=endpoint
transport=transport-udp
context=fax-in
disallow=all
allow=alaw,ulaw
aors=1und1-aor
auth=1und1-auth
from_domain=${PJSIP_FROMDOMAIN}
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
match=${PJSIP_SERVER}

[1und1-reg]
type=registration
outbound_auth=1und1-auth
server_uri=sip:${PJSIP_SERVER}
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

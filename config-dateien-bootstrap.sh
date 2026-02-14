#!/usr/bin/env bash
# kienzlefax-bootstrap.v2.sh
#
# - Backups *.old.kienzlefax
# - schreibt die "wirklich wichtigen" Asterisk-Configs korrekt:
#     /etc/asterisk/pjsip.conf
#     /etc/asterisk/extensions.conf
#     /etc/asterisk/rtp.conf
#     /etc/asterisk/iax.conf (optional/iaxmodem)
# - legt /etc/systemd/system/iaxmodem@.service korrekt an (optional)
# - erstellt Fax-Spools und Rechte
#
# Ziel: nach Scriptlauf sollte Asterisk sofort mit den Basis-Settings laufen,
#       Fax-In/Fax-Out Dialplan aktiv sein, RTP-Ports konsistent sein.
#
set -euo pipefail

STAMP_SUFFIX="old.kienzlefax"

# -----------------------------------------------------------------------------
# 0) PARAMETER: HIER anpassen
# -----------------------------------------------------------------------------

# SIP / Provider / NAT
PUBLIC_FQDN="XXXXXdyn-dnsXXXX"          # external_signaling_address/external_media_address
SIP_BIND_IP="0.0.0.0"
SIP_BIND_PORT="5070"

# lokale Netze (mehrere möglich)
LOCAL_NETS=("10.0.0.0/8" "192.168.0.0/16")

# RTP-Ports (muss zum Router-FW passen)
RTP_START="12000"
RTP_END="12049"

# 1&1 Registration / Endpoint
SIP_SERVER_URI="sip:sip.1und1.de"
SIP_CLIENT_URI="sip:4923XXXXX@sip.1und1.de"     # <-- anpassen
SIP_CONTACT_USER="4923XXXXXXX"                  # <-- anpassen
SIP_USERNAME="4923XXXXXXXXX"                    # <-- anpassen
SIP_PASSWORD="XXXXXXXXXXXX"                     # <-- anpassen

FROM_USER="4923XXXXXXXXXX"                      # <-- anpassen (Absender)
FROM_DOMAIN="sip.1und1.de"

# eingehende Rufnummer für Fax (DID)
FAX_DID="4923XXXXXXXX"                          # <-- anpassen

# 1&1 inbound match (wie bei dir)
PROVIDER_MATCH_NET="212.227.0.0/16"

# Fax-Defaults (konservativ, stabil)
FAX_ECM="yes"
FAX_MAXRATE="9600"

# Spool
SPOOL_TIFF_DIR="/var/spool/asterisk/fax1"
SPOOL_PDF_DIR="/var/spool/asterisk/fax"

# optional: iaxmodem/hylafax Pfad (nur wenn du es nutzt)
ENABLE_IAXMODEM="yes"     # "yes" oder "no"
IAXMODEM_BIN_CANDIDATES=(iaxmodem /usr/bin/iaxmodem /usr/sbin/iaxmodem)
IAXMODEM_SECRET="faxsecret"   # ACHTUNG: wenn du veröffentlichst -> anonymisieren
IAXMODEM_PORT0="4570"
IAXMODEM_PORT1="4571"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
say() { echo -e "\n### $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (sudo)."
}

backup_file() {
  local f="$1"
  if [ -e "$f" ] && [ ! -e "${f}.${STAMP_SUFFIX}" ]; then
    cp -a "$f" "${f}.${STAMP_SUFFIX}"
    echo "backup: $f -> ${f}.${STAMP_SUFFIX}"
  fi
}

install_dir() {
  local d="$1" owner="$2" mode="$3"
  install -d -m "$mode" "$d"
  chown "$owner" "$d" || true
}

detect_bin() {
  for p in "$@"; do
    if command -v "$p" >/dev/null 2>&1; then
      command -v "$p"
      return 0
    fi
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

write_file() {
  local f="$1"; shift
  install -d -m 0755 "$(dirname "$f")"
  cat >"$f" <<'EOF'
__CONTENT__
EOF
  # replace placeholder with passed content safely
  perl -0777 -i -pe 's/__CONTENT__/$ENV{KZ_CONTENT}/s' "$f"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
require_root

say "1) Backups der relevanten Konfigurationsdateien (*.${STAMP_SUFFIX})"
for f in \
  /etc/asterisk/pjsip.conf \
  /etc/asterisk/extensions.conf \
  /etc/asterisk/iax.conf \
  /etc/asterisk/rtp.conf
do
  backup_file "$f"
done

if [ "${ENABLE_IAXMODEM}" = "yes" ]; then
  for f in \
    /etc/iaxmodem/ttyIAX0.conf \
    /etc/iaxmodem/ttyIAX1.conf \
    /etc/systemd/system/iaxmodem@.service
  do
    backup_file "$f"
  done
fi

say "2) Spool-Verzeichnisse + Rechte"
install_dir "$SPOOL_TIFF_DIR" asterisk:asterisk 0755
install_dir "$SPOOL_PDF_DIR"  asterisk:asterisk 0755

say "3) /etc/asterisk/rtp.conf schreiben (Router-Portrange konsistent)"
export KZ_CONTENT="$(cat <<EOF
[general]
rtpstart=${RTP_START}
rtpend=${RTP_END}
icesupport=no
strictrtp=yes
EOF
)"
write_file /etc/asterisk/rtp.conf

say "4) /etc/asterisk/pjsip.conf schreiben (Transport/NAT/1&1)"
# LOCAL_NETS als mehrere Zeilen
LOCAL_NET_LINES=""
for n in "${LOCAL_NETS[@]}"; do
  LOCAL_NET_LINES+=$'local_net = '"$n"$'\n'
done

export KZ_CONTENT="$(cat <<EOF
[transport-udp]
type=transport
protocol=udp
bind=${SIP_BIND_IP}:${SIP_BIND_PORT}

; NAT / extern
external_signaling_address = ${PUBLIC_FQDN}
external_media_address     = ${PUBLIC_FQDN}

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
password=${SIP_PASSWORD}

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

; 1&1: kein T.38 → aus (Fallback testen!)
t38_udptl=no
t38_udptl_nat=no
;t38_udptl_ec=no

from_user=${FROM_USER}
from_domain=${FROM_DOMAIN}

send_pai=yes
send_rpid=yes
trust_id_outbound=yes

; WICHTIG: jitterbuffer gehört NICHT hierher (siehe extensions.conf)
;use_jitterbuffer=yes
;jbimpl=adaptive
;jbmaxsize=400
;jbtargetextra=200

[1und1-identify]
type=identify
endpoint=1und1-endpoint
match=${PROVIDER_MATCH_NET}
EOF
)"
write_file /etc/asterisk/pjsip.conf

say "5) /etc/asterisk/extensions.conf schreiben (Fax-in/Fax-out, Jitterbuffer korrekt, UniqueID-Zählerteil)"
export KZ_CONTENT="$(cat <<'EOF'
; -------------------------------------------------------------------
; /etc/asterisk/extensions.conf  (kienzlefax)
; Wichtig: JITTERBUFFER gehört hierher (pro Call) – nicht in pjsip.conf
; -------------------------------------------------------------------

[general]
static=yes
writeprotect=no
clearglobalvars=no

; ---------------------------
; FAX OUT
; ---------------------------
[fax-out]

; 49 + Ortsnetznummer ohne 0 → nationales Format 0...
exten => _49X.,1,NoOp(FAX OUT normalize 49... -> national)
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,Set(NORM=0${EXTEN:2})
 same => n,NoOp(NORMALIZED=${NORM})
 same => n,Set(FAXOPT(ecm)=__FAX_ECM__)
 same => n,Set(FAXOPT(maxrate)=__FAX_MAXRATE__)
 same => n,Set(CALLERID(num)=__FROM_USER__)
 same => n,Set(CALLERID(name)=Fax)
 same => n,Dial(PJSIP/${NORM}@1und1-endpoint,60)
 same => n,Hangup()

; Falls bereits national gewählt wurde
exten => _0X.,1,NoOp(FAX OUT national)
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,Set(FAXOPT(ecm)=__FAX_ECM__)
 same => n,Set(FAXOPT(maxrate)=__FAX_MAXRATE__)
 same => n,Set(CALLERID(num)=__FROM_USER__)
 same => n,Set(CALLERID(name)=Fax)
 same => n,Dial(PJSIP/${EXTEN}@1und1-endpoint,60)
 same => n,Hangup()


; ---------------------------
; FAX IN
; ---------------------------
[fax-in]
exten => __FAX_DID__,1,NoOp(Inbound Fax)
 same => n,Answer()

 same => n,Set(FAXOPT(ecm)=__FAX_ECM__)
 same => n,Set(FAXOPT(maxrate)=__FAX_MAXRATE__)
 same => n,Set(JITTERBUFFER(adaptive)=default)

 ; Zeitstempel EINMAL festhalten
 same => n,Set(FAXSTAMP=${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)})

 ; Absendernummer "sanitizen"
 same => n,Set(FROMRAW=${CALLERID(num)})
 same => n,Set(FROM=${FILTER(0-9,${FROMRAW})})
 same => n,ExecIf($["${FROM}"=""]?Set(FROM=unknown))

 ; UniqueID nur Zählerteil nach dem Punkt verwenden (wie gewünscht)
 same => n,Set(UID=${CUT(UNIQUEID,.,2)})
 same => n,ExecIf($["${UID}"=""]?Set(UID=${UNIQUEID}))

 ; Dateibasis: Datum + Absender + UID
 same => n,Set(FAXBASE=${FAXSTAMP}_${FROM}_${UID})

 ; Pfade
 same => n,Set(TIFF=__SPOOL_TIFF_DIR__/${FAXBASE}.tif)
 same => n,Set(PDF=__SPOOL_PDF_DIR__/${FAXBASE}.pdf)

 ; Empfang
 same => n,ReceiveFAX(${TIFF})

 ; Status loggen
 same => n,NoOp(FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} PAGES=${FAXPAGES})

 ; Best effort PDF auch bei Abbruch, wenn TIFF existiert
 same => n,Set(HASFILE=${STAT(e,${TIFF})})
 same => n,Set(SIZE=${STAT(s,${TIFF})})
 same => n,GotoIf($[${HASFILE} & ${SIZE} > 0]?to_pdf:no_file)

 same => n(to_pdf),System(tiff2pdf -o ${PDF} ${TIFF})
 same => n,NoOp(tiff2pdf SYSTEMSTATUS=${SYSTEMSTATUS})
 same => n,GotoIf($["${SYSTEMSTATUS}"="SUCCESS"]?cleanup:keep_tiff)

 same => n(cleanup),System(rm -f ${TIFF})
 same => n,Hangup()

 same => n(keep_tiff),NoOp(PDF failed or partial - keeping TIFF: ${TIFF})
 same => n,Hangup()

 same => n(no_file),NoOp(No TIFF created (receive likely failed early). Nothing to convert.)
 same => n,Hangup()
EOF
)"
# Platzhalter ersetzen
export KZ_CONTENT="${KZ_CONTENT//__FAX_ECM__/${FAX_ECM}}"
export KZ_CONTENT="${KZ_CONTENT//__FAX_MAXRATE__/${FAX_MAXRATE}}"
export KZ_CONTENT="${KZ_CONTENT//__FROM_USER__/${FROM_USER}}"
export KZ_CONTENT="${KZ_CONTENT//__FAX_DID__/${FAX_DID}}"
export KZ_CONTENT="${KZ_CONTENT//__SPOOL_TIFF_DIR__/${SPOOL_TIFF_DIR}}"
export KZ_CONTENT="${KZ_CONTENT//__SPOOL_PDF_DIR__/${SPOOL_PDF_DIR}}"
write_file /etc/asterisk/extensions.conf

say "6) Optional: /etc/asterisk/iax.conf + iaxmodem systemd Template"
if [ "${ENABLE_IAXMODEM}" = "yes" ]; then
  IAXMODEM_BIN="$(detect_bin "${IAXMODEM_BIN_CANDIDATES[@]}" || true)"
  if [ -z "${IAXMODEM_BIN:-}" ]; then
    echo "WARN: iaxmodem nicht gefunden. Unit/Configs werden dennoch geschrieben."
    IAXMODEM_BIN="/usr/bin/iaxmodem"
  fi

  export KZ_CONTENT="$(cat <<EOF
[general]
bindport=4569
bindaddr=0.0.0.0
; wichtig für lokale Tests:
delayreject=yes

[iaxmodem0]
type=friend
username=iaxmodem0
secret=${IAXMODEM_SECRET}
host=dynamic
context=fax-out
auth=md5
disallow=all
allow=alaw
requirecalltoken=no
jitterbuffer=no
forcejitterbuffer=no

[iaxmodem1]
type=friend
username=iaxmodem1
secret=${IAXMODEM_SECRET}
host=dynamic
context=fax-out
auth=md5
disallow=all
allow=alaw
requirecalltoken=no
jitterbuffer=no
forcejitterbuffer=no
EOF
)"
  write_file /etc/asterisk/iax.conf

  install -d -m 0755 /etc/iaxmodem
  cat >/etc/iaxmodem/ttyIAX0.conf <<EOF
device          /dev/ttyIAX0
owner           uucp:uucp
mode            660
port            ${IAXMODEM_PORT0}
refresh         60
server          127.0.0.1
peername        iaxmodem0
secret          ${IAXMODEM_SECRET}
codec           alaw
EOF

  cat >/etc/iaxmodem/ttyIAX1.conf <<EOF
device          /dev/ttyIAX1
owner           uucp:uucp
mode            660
port            ${IAXMODEM_PORT1}
refresh         60
server          127.0.0.1
peername        iaxmodem1
secret          ${IAXMODEM_SECRET}
codec           alaw
EOF

  # Korrektes systemd-Template: nutzt -c /etc/iaxmodem/%i.conf
  install -d -m 0755 /etc/systemd/system
  cat >/etc/systemd/system/iaxmodem@.service <<EOF
[Unit]
Description=IAXmodem instance for %i
After=network-online.target asterisk.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${IAXMODEM_BIN} -c /etc/iaxmodem/%i.conf
Restart=on-failure
RestartSec=2
KillMode=control-group
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable iaxmodem@ttyIAX0.service >/dev/null 2>&1 || true
  systemctl enable iaxmodem@ttyIAX1.service >/dev/null 2>&1 || true
fi

say "7) Asterisk reload/restart"
if systemctl list-unit-files | grep -q '^asterisk\.service'; then
  systemctl restart asterisk.service || true
else
  echo "Hinweis: asterisk.service nicht gefunden (OK wenn du Asterisk anders startest)."
fi

say "8) Kurzchecks (optional)"
if command -v asterisk >/dev/null 2>&1; then
  asterisk -rx "core show version" 2>/dev/null || true
  asterisk -rx "module show like fax" 2>/dev/null || true
  asterisk -rx "fax show capabilities" 2>/dev/null || true
  asterisk -rx "pjsip show registrations" 2>/dev/null || true
fi

echo
echo "DONE."
echo "Wichtigste Dateien jetzt gesetzt:"
echo " - /etc/asterisk/pjsip.conf"
echo " - /etc/asterisk/extensions.conf"
echo " - /etc/asterisk/rtp.conf"
[ "${ENABLE_IAXMODEM}" = "yes" ] && echo " - /etc/asterisk/iax.conf + /etc/iaxmodem/*.conf + iaxmodem@.service"
echo
echo "Nächste Schritte:"
echo " - Nummern/Secrets oben final eintragen (oder per ENV/Secrets-Management)"
echo " - Danach immer: systemctl restart asterisk"
EOF
)"

# write_file nutzt Perl placeholder; wir müssen das Script selbst schreiben -> einfacher:
# (wir haben oben write_file genutzt – hier am Ende ist nur Ausgabe)
exit 0

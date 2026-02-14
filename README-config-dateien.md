## Ports und anbieter
- ich habe weiterleitungen UDP für die port 5070 und 12000-12049 im router eingerichtet
- bei meiner entwicklung hatte ich nur einen 1&1-anschluss zur verfügung der kein T38 nutzt, daher teilweise konservative einstellungen
- optimal ist ein telekom.business anschluss, da kann man T38 aktivieren was technisch am schönsten ist!
- jitter-buffer ist extrem wichtig musste ich lernen -> - gute faxe brechen auch bei vielen seiten nicht ab
- bei schlechten verbnindungen/konfiguration wird es ab 8 oder 10 seten schon problematisch
- immer lange faxe testen
- als gegenstelle für tests bietet sich eine fritzbox an, dort faxempfang auf einer anderen nummer einschalten
- auch wenn man T38 hat unbedingt alles ohne T38 testen wegen fallback


## Besonders wichtige dateien:
- extensions.conf enthät die dialpläne
- pjsip.conf enthält die einwahldaten SIP und konfiguriert den anschluss
- IAX.conf enthält die verbindung zum hylafax das darüber sendet
- rtp.conf muss zu den weiterleitungen im router passen
- diese IAX-modem-services müssen funktionieren, da kann man sich gut vom LLM helfen lassen nötigenfalls
- der rest ist vermutlich relativ obsolet aber lieber haben als brauchen!

## Ablauf
- vorbereiten des systems
- die relevanten dateien s.o. per editor anpassen wie z.b. "nano /etc/asterisk/extensions.conf" usw
- immer nach änderungen services neu starten oder booten
- debug-logs usw in einer der anderen dateien, da bekommt man alle infos wenn was nicht läuft


**Vorbereitung des systems, anlage von ordnern und beispieldateien**
```bash
#!/usr/bin/env bash
# kienzlefax-bootstrap.sh
#
# Bootstrap für Asterisk+Fax (SpanDSP) + optional HylaFAX/iaxmodem:
# - legt Verzeichnisse an
# - setzt sinnvolle Rechte/Owner
# - legt systemd Units (iaxmodem@ttyIAX0/1) an (falls iaxmodem genutzt wird)
# - erstellt Placeholder-Konfigs (ohne Secrets) damit du danach nur noch "einbauen" musst
# - legt Backups der relevanten Config-Dateien als *.old.kienzlefax an
#
# ACHTUNG: Script ist absichtlich "vorsichtig" (idempotent, keine Secrets).
# Prüfe am Ende die Pfade/Units und passe Konfigs an.

set -euo pipefail

STAMP_SUFFIX="old.kienzlefax"

# -------- helpers --------
say() { echo -e "\n### $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

backup_file() {
  local f="$1"
  if [ -e "$f" ] && [ ! -e "${f}.${STAMP_SUFFIX}" ]; then
    cp -a "$f" "${f}.${STAMP_SUFFIX}"
    echo "backup: $f -> ${f}.${STAMP_SUFFIX}"
  fi
}

ensure_dir() {
  local d="$1" owner="$2" mode="$3"
  install -d -m "$mode" "$d"
  chown "$owner" "$d" || true
}

ensure_user_groups() {
  local user="$1"; shift
  if id "$user" >/dev/null 2>&1; then
    for g in "$@"; do
      if getent group "$g" >/dev/null 2>&1; then
        usermod -aG "$g" "$user" || true
      fi
    done
  fi
}

write_file_if_missing() {
  local f="$1"
  shift
  if [ ! -e "$f" ]; then
    install -d -m 0755 "$(dirname "$f")"
    cat >"$f" <<'EOF'
'"$@"'
EOF
  fi
}

detect_bin() {
  # prints first existing path
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

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (sudo)."
}

# -------- main --------
require_root

say "1) Backups relevanter Konfigurationen anlegen (*.${STAMP_SUFFIX})"

# Asterisk
for f in \
  /etc/asterisk/pjsip.conf \
  /etc/asterisk/extensions.conf \
  /etc/asterisk/iax.conf \
  /etc/asterisk/rtp.conf \
  /etc/asterisk/modules.conf \
  /etc/asterisk/fax.conf \
  /etc/asterisk/logger.conf \
  /etc/asterisk/asterisk.conf \
  /etc/asterisk/http.conf \
  /etc/asterisk/sorcery.conf
do
  backup_file "$f"
done

# HylaFAX
for f in \
  /etc/hylafax/hyla.conf \
  /etc/hylafax/FaxDispatch \
  /etc/hylafax/hosts.hfaxd \
  /var/spool/hylafax/etc/config.ttyIAX0 \
  /var/spool/hylafax/etc/config.ttyIAX1 \
  /var/spool/hylafax/etc/setup.cache
do
  backup_file "$f"
done

# iaxmodem
for f in \
  /etc/iaxmodem/iaxmodem.conf \
  /etc/iaxmodem/ttyIAX0.conf \
  /etc/iaxmodem/ttyIAX1.conf \
  /etc/default/iaxmodem
do
  backup_file "$f"
done

say "2) Verzeichnisse anlegen (Fax-Spool, Logs, etc.)"

# Asterisk Fax-Spool
ensure_dir /var/spool/asterisk/fax  asterisk:asterisk 0755
ensure_dir /var/spool/asterisk/fax1 asterisk:asterisk 0755

# Optional: eigenes Log-Verzeichnis
ensure_dir /var/log/kienzlefax root:root 0755

# HylaFAX Spool exists usually; ensure base perms don't explode
if [ -d /var/spool/hylafax ]; then
  chmod 0755 /var/spool/hylafax || true
fi

say "3) Gruppen/Rechte vorbereiten"

# Für tty/pty: asterisk häufig in dialout/uucp sinnvoll (variiert je Distro)
ensure_user_groups asterisk dialout uucp

# HylaFAX nutzt oft uucp/dialout; je nach Setup:
ensure_user_groups uucp dialout || true

say "4) Placeholder-Konfigs erstellen (falls nicht vorhanden) – ohne Secrets"

# --- Asterisk placeholders ---
if [ ! -e /etc/asterisk/extensions.conf ]; then
  install -d -m 0755 /etc/asterisk
  cat >/etc/asterisk/extensions.conf <<'EOF'
; extensions.conf (Placeholder – bitte anpassen)
;
; Hinweis:
; - Fax-Empfang direkt in Asterisk: ReceiveFAX(...)
; - Dateinamen/Umwandlung nach PDF machst du später im Dialplan.

[general]
static=yes
writeprotect=no
clearglobalvars=no

[fax-in]
; Beispiel:
; exten => 4923XXXXXXX,1,NoOp(Inbound Fax)
;  same => n,Answer()
;  same => n,Set(FAXOPT(ecm)=no)
;  same => n,Set(FAXOPT(maxrate)=9600)
;  same => n,ReceiveFAX(/var/spool/asterisk/fax1/%Y%m%d-%H%M%S.tif)
;  same => n,Hangup()

; Platzhalter-Default:
exten => _X.,1,Hangup()
EOF
fi

if [ ! -e /etc/asterisk/pjsip.conf ]; then
  install -d -m 0755 /etc/asterisk
  cat >/etc/asterisk/pjsip.conf <<'EOF'
; pjsip.conf (Placeholder – bitte anpassen)
; Hier gehören deine Provider-Registrierung + Endpoint rein.

[global]
type=global
user_agent=KienzleFax-Asterisk

; Beispiel-Transport (typisch):
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5070

; Provider auth/aor/registration/endpoint dann hier ergänzen.
EOF
fi

# IAX (nur falls iaxmodem genutzt wird)
if [ ! -e /etc/asterisk/iax.conf ]; then
  install -d -m 0755 /etc/asterisk
  cat >/etc/asterisk/iax.conf <<'EOF'
; iax.conf (Placeholder – falls iaxmodem genutzt wird)
[general]
bindport=4569
bindaddr=127.0.0.1
jitterbuffer=no

; Beispiel-Peer für iaxmodem:
; [iaxmodem0]
; type=friend
; host=127.0.0.1
; port=4570
; secret=CHANGEME
; context=fax-out
; disallow=all
; allow=alaw
EOF
fi

# --- iaxmodem placeholders ---
install -d -m 0755 /etc/iaxmodem

if [ ! -e /etc/iaxmodem/ttyIAX0.conf ]; then
  cat >/etc/iaxmodem/ttyIAX0.conf <<'EOF'
# ttyIAX0.conf (Placeholder)
# Bitte anpassen: secret/peername/port usw.

device          /dev/ttyIAX0
owner           uucp:uucp
mode            660
port            4570
refresh         60
server          127.0.0.1
peername        iaxmodem0
secret          CHANGEME
codec           alaw
EOF
fi

if [ ! -e /etc/iaxmodem/ttyIAX1.conf ]; then
  cat >/etc/iaxmodem/ttyIAX1.conf <<'EOF'
# ttyIAX1.conf (Placeholder)
device          /dev/ttyIAX1
owner           uucp:uucp
mode            660
port            4571
refresh         60
server          127.0.0.1
peername        iaxmodem1
secret          CHANGEME
codec           alaw
EOF
fi

# --- HylaFAX placeholders (nur wenn HylaFAX vorhanden/gewünscht) ---
if [ -d /var/spool/hylafax/etc ]; then
  if [ ! -e /var/spool/hylafax/etc/config.ttyIAX0 ]; then
    cat >/var/spool/hylafax/etc/config.ttyIAX0 <<'EOF'
# config.ttyIAX0 (Placeholder)
# HylaFAX Modem-Config für /dev/ttyIAX0 (iaxmodem)
#
# Wichtig: Device muss mit iaxmodem zusammenpassen.
# Du füllst später die passenden Parameter ein.

ModemType:       Class1
ModemRate:       19200
ModemFlowControl: rtscts
EOF
  fi
  if [ ! -e /var/spool/hylafax/etc/config.ttyIAX1 ]; then
    cat >/var/spool/hylafax/etc/config.ttyIAX1 <<'EOF'
# config.ttyIAX1 (Placeholder)
ModemType:       Class1
ModemRate:       19200
ModemFlowControl: rtscts
EOF
  fi
fi

say "5) systemd Units für iaxmodem@ttyIAX0/ttyIAX1 anlegen (native, sauber stoppbar)"

IAXMODEM_BIN="$(detect_bin iaxmodem /usr/sbin/iaxmodem /usr/bin/iaxmodem || true)"
if [ -z "${IAXMODEM_BIN:-}" ]; then
  echo "Hinweis: iaxmodem binary nicht gefunden – Units werden trotzdem als Template angelegt."
  IAXMODEM_BIN="/usr/sbin/iaxmodem"
fi

install -d -m 0755 /etc/systemd/system

# Template unit (nutzt /etc/iaxmodem/%i.conf)
cat >/etc/systemd/system/iaxmodem@.service <<EOF
[Unit]
Description=IAXmodem instance for %i
After=network-online.target asterisk.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
# Konfigdatei: /etc/iaxmodem/%i.conf (z.B. ttyIAX0.conf)
ExecStart=${IAXMODEM_BIN} -c /etc/iaxmodem/%i.conf
Restart=on-failure
RestartSec=2
KillMode=control-group
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

say "6) Dienste aktivieren (nur wenn sie existieren) – asterisk/hylafax nur enable/restart, iaxmodem instances enable"

systemctl daemon-reload

# Asterisk (falls installiert)
if systemctl list-unit-files | grep -q '^asterisk\.service'; then
  systemctl enable asterisk.service >/dev/null 2>&1 || true
  systemctl restart asterisk.service || true
else
  echo "Hinweis: asterisk.service nicht gefunden (OK, wenn du Asterisk anders startest)."
fi

# HylaFAX (falls installiert)
if systemctl list-unit-files | grep -Eq '^(hylafax|hylafax\.service)'; then
  systemctl enable hylafax.service >/dev/null 2>&1 || true
  systemctl restart hylafax.service || true
else
  # manche Distros splitten: faxq/hfaxd/faxgetty
  if systemctl list-unit-files | grep -q '^faxq\.service'; then
    systemctl enable faxq.service hfaxd.service >/dev/null 2>&1 || true
    systemctl restart faxq.service hfaxd.service || true
  else
    echo "Hinweis: HylaFAX systemd Units nicht gefunden (OK, wenn HylaFAX nicht genutzt wird)."
  fi
fi

# iaxmodem instances (nur aktivieren, wenn Konfig vorhanden ist)
if [ -e /etc/iaxmodem/ttyIAX0.conf ]; then
  systemctl enable iaxmodem@ttyIAX0.service >/dev/null 2>&1 || true
  systemctl restart iaxmodem@ttyIAX0.service || true
fi
if [ -e /etc/iaxmodem/ttyIAX1.conf ]; then
  systemctl enable iaxmodem@ttyIAX1.service >/dev/null 2>&1 || true
  systemctl restart iaxmodem@ttyIAX1.service || true
fi

say "7) Kurz-Status"
systemctl --no-pager status iaxmodem@ttyIAX0.service 2>/dev/null || true
systemctl --no-pager status iaxmodem@ttyIAX1.service 2>/dev/null || true
systemctl --no-pager status asterisk.service 2>/dev/null || true

say "DONE"
echo "Nächste Schritte:"
echo " - /etc/asterisk/pjsip.conf + /etc/asterisk/extensions.conf (Fax-Dialplan) befüllen"
echo " - optional /etc/asterisk/iax.conf + /etc/iaxmodem/ttyIAX0.conf secrets/ports/peername setzen"
echo " - danach: systemctl restart asterisk iaxmodem@ttyIAX0 (und ggf. hylafax)"


```



## Alle config-dateien
- die wirklich wichtigen dateien davon siehe oben!
  
```bash

root@fax:/home/faxuser# # Sammel-Export: alle typischen Dateien, die man für Asterisk(PJSIP)+Fax(SpanDSP)+HylaFAX+iaxmodem anfasst.
# Ausgabe geht auf STDOUT (zum Redirect z.B.: ./collect.sh > configs.txt)
# WICHTIG: Enthält potentiell Passwörter/Secrets/Telefonnummern/IPs – bitte vor Veröffentlichung anonymisieren!

set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

hdr() {
  echo
  echo "######################################################################"
  echo "# $1"
  echo "######################################################################"
}

show_file() {
  local f="$1"
  hdr "FILE: $f"
  if [ -r "$f" ]; then
    sed -n '1,2000p' "$f"
  else
    echo "# (nicht vorhanden oder nicht lesbar)"
  fi
}

show_unit() {
  local u="$1"
  hdr "SYSTEMD UNIT: $u"
  if have systemctl; then
    systemctl cat "$u" 2>/dev/null || echo "# (unit nicht gefunden)"
  else
    echo "# systemctl nicht vorhanden"
  fi
}

show_cmd() {
  local title="$1"; shift
  hdr "CMD: $title"
  ( "$@" ) 2>&1 || true
}

###############################################################################
# Asterisk / PJSIP / Fax
###############################################################################
show_file /etc/asterisk/pjsip.conf
show_file /etc/asterisk/extensions.conf

# Falls du dialplan includes nutzt (häufig):
show_file /etc/asterisk/extensions_custom.conf
show_file /etc/asterisk/extensions.ael

# Module-Ladung / Autoload / noload / menuselect-relevante Konfig
show_file /etc/asterisk/modules.conf

# Fax-Konfig (je nach Installation genutzt)
show_file /etc/asterisk/fax.conf

# RTP / NAT / Ports
show_file /etc/asterisk/rtp.conf

# Allgemeine Asterisk Settings, oft für Pfade/Directory Permissions relevant
show_file /etc/asterisk/asterisk.conf

# Logging (falls du fax debug / verbose Anpassungen persistiert hast)
show_file /etc/asterisk/logger.conf

# Wenn du IAX2 noch im Einsatz hast (iaxmodem-Variante)
show_file /etc/asterisk/iax.conf

###############################################################################
# HylaFAX / iaxmodem
###############################################################################
# HylaFAX zentrale Konfiguration
show_file /etc/hylafax/hyla.conf
show_file /etc/hylafax/FaxDispatch
show_file /etc/hylafax/hosts.hfaxd

# Modem-spezifische HylaFAX configs (je nach Device-Namen)
show_file /var/spool/hylafax/etc/config.ttyIAX0
show_file /var/spool/hylafax/etc/config.ttyIAX1
show_file /var/spool/hylafax/etc/config.ttyACM0
show_file /var/spool/hylafax/etc/config.modem
echo "# DONE"IP registrations" bash -lc 'asterisk -rx "pjsip show registrations" 2>/dev/null || true''

######################################################################
# FILE: /etc/asterisk/pjsip.conf
######################################################################
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5070

external_signaling_address = kiha.kidr.de
external_media_address     = kiha.kidr.de

local_net = 10.0.0.0/8
local_net = 192.168.0.0/16



[1und1]
type=registration
transport=transport-udp
outbound_auth=1und1-auth
server_uri=sip:sip.1und1.de
client_uri=sip:4923XXXXX@sip.1und1.de
contact_user=4923XXXXXXX
retry_interval=60
forbidden_retry_interval=600
expiration=300


[1und1-auth]
type=auth
auth_type=userpass
username=4923XXXXXXXXX
password=XXXXXXXXXXXX

[1und1-aor]
type=aor
contact=sip:sip.1und1.de

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
from_user=4923XXXXXXXXXX
from_domain=sip.1und1.de
send_pai=yes
send_rpid=yes
trust_id_outbound=yes

; ===== JITTERBUFFER (PJSIP/chan_pjsip korrekt) =====
; jitterbuffer hat hier nichts verloren, muss in die extensions.conf!
;use_jitterbuffer=yes
;jbimpl=adaptive
;jbmaxsize=400
;jbtargetextra=200


[1und1-identify]
type=identify
endpoint=1und1-endpoint

; zulaessiger netzblock bei meinem 1und1-anschluss fuer eingehendes
match=212.227.0.0/16




######################################################################
# FILE: /etc/asterisk/extensions.conf
######################################################################
[fax-out]

; 49 + Ortsnetznummer ohne 0 → nationales Format 0...
exten => _49X.,1,NoOp(FAX OUT normalize 49... -> national)
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same  => n,Set(NORM=0${EXTEN:2})
 same  => n,NoOp(NORMALIZED=${NORM})
 same  => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,Set(CALLERID(num)=4923XXXXXXXXXX)
 same => n,Set(CALLERID(name)=Fax)
; same  => n,Set(FAXOPT(gateway)=yes)
 same  => n,Dial(PJSIP/${NORM}@1und1-endpoint,60)
 same  => n,Hangup()

; Falls bereits national gewählt wurde
exten => _0X.,1,NoOp(FAX OUT national)
 same => n,Set(JITTERBUFFER(adaptive)=default) 
 same  => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,Set(CALLERID(num)=4923XXXXXXXXXX)
 same => n,Set(CALLERID(name)=Fax) 
 same  => n,Dial(PJSIP/${EXTEN}@1und1-endpoint,60)
 same  => n,Hangup()



[fax-in]
; --- Fax-In (best effort TIFF->PDF), Dateiname: DATUMZEIT_ABSENDER_...
; Beispiel: 20260213-145931_+491701234567_1707793771.12.pdf

exten => 4923XXXXXXXX,1,NoOp(Inbound Fax)
 same => n,Answer()

 ; Optionen nach Bedarf
 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
same => n,Set(JITTERBUFFER(adaptive)=default)
; same  => n,Set(FAXOPT(gateway)=yes)

 ; Zeitstempel EINMAL festhalten (sonst ändert er sich)
 same => n,Set(FAXSTAMP=${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)})

 ; Absendernummer "sanitizen" (kein +, keine Leerzeichen)
 same => n,Set(FROMRAW=${CALLERID(num)})
 same => n,Set(FROM=${FILTER(0-9,${FROMRAW})})
 same => n,ExecIf($["${FROM}"=""]?Set(FROM=unknown))

 ; Dateibasis: Datum + Absender + UniqueID (eindeutig auch bei Parallelfax)
 same => n,Set(FAXBASE=${FAXSTAMP}_${FROM}_${UNIQUEID})

 ; Pfade
 same => n,Set(TIFF=/var/spool/asterisk/fax1/${FAXBASE}.tif)
 same => n,Set(PDF=/var/spool/asterisk/fax/${FAXBASE}.pdf)

 ; Empfang
 same => n,ReceiveFAX(${TIFF})

 ; Status loggen
 same => n,NoOp(FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} PAGES=${FAXPAGES})

 ; --- Best effort: wenn TIFF existiert und >0 Bytes -> PDF versuchen, auch bei Abbruch
 same => n,Set(HASFILE=${STAT(e,${TIFF})})
 same => n,Set(SIZE=${STAT(s,${TIFF})})
 same => n,GotoIf($[${HASFILE} & ${SIZE} > 0]?to_pdf:no_file)

 same => n(to_pdf),System(tiff2pdf -o ${PDF} ${TIFF})
 same => n,NoOp(tiff2pdf SYSTEMSTATUS=${SYSTEMSTATUS})
 ; TIFF nur löschen, wenn PDF-Konvertierung erfolgreich
 same => n,GotoIf($["${SYSTEMSTATUS}"="SUCCESS"]?cleanup:keep_tiff)

 same => n(cleanup),System(rm -f ${TIFF})
 same => n,Hangup()

 same => n(keep_tiff),NoOp(PDF failed or partial - keeping TIFF: ${TIFF})
 same => n,Hangup()

 same => n(no_file),NoOp(No TIFF created (receive likely failed early). Nothing to convert.)
 same => n,Hangup()

######################################################################
# FILE: /etc/asterisk/extensions_custom.conf
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /etc/asterisk/extensions.ael
######################################################################
//
// Example AEL config file
//
//
// Static extension configuration file, used by
// the pbx_ael module. This is where you configure all your
// inbound and outbound calls in Asterisk.
//
// This configuration file is reloaded
// - With the "ael reload" command in the CLI
// - With the "reload" command (that reloads everything) in the CLI

// The "Globals" category contains global variables that can be referenced
// in the dialplan by using the GLOBAL dialplan function:
//  ${GLOBAL(VARIABLE)}
// ${${GLOBAL(VARIABLE)}} or ${text${GLOBAL(VARIABLE)}} or any hybrid
// Unix/Linux environmental variables are reached with the ENV dialplan
// function: ${ENV(VARIABLE)}
//

// NOTE! NOTE! NOTE!
// Asterisk by default will load both extensions.conf and extensions.ael files.
// Upon loading these files the dialplans generated from both with be merged,
// so you must make sure that you don't have any overlapping contexts or global
// variables. If you do, then unexpected behavior may result when the data is
// merged.
// NOTE! NOTE! NOTE!

globals {
	CONSOLE-AEL="Console/dsp"; 		// Console interface for demo
	//CONSOLE-AEL=Zap/1;
	//CONSOLE-AEL=Phone/phone0;
	OUTBOUND-TRUNK="Zap/g2";		// Trunk interface
	//
	// Note the 'g2' in the OUTBOUND-TRUNK variable above. It specifies which group (defined
	// in chan_dahdi.conf) to dial, i.e. group 2, and how to choose a channel to use in
	// the specified group. The four possible options are:
	//
	// g: select the lowest-numbered non-busy DAHDI channel
	//    (aka. ascending sequential hunt group).
	// G: select the highest-numbered non-busy DAHDI channel
	//    (aka. descending sequential hunt group).
	// r: use a round-robin search, starting at the next highest channel than last
	//    time (aka. ascending rotary hunt group).
	// R: use a round-robin search, starting at the next lowest channel than last
	//    time (aka. descending rotary hunt group).
	//
	OUTBOUND-TRUNKMSD=1;					// MSD digits to strip (usually 1 or 0)
	//OUTBOUND-TRUNK2=IAX2/user:pass@provider;
};

//
// Any category other than "General" and "Globals" represent
// extension contexts, which are collections of extensions.
//
// Extension names may be numbers, letters, or combinations
// thereof. If an extension name is prefixed by a '_'
// character, it is interpreted as a pattern rather than a
// literal.  In patterns, some characters have special meanings:
//
//   X - any digit from 0-9
//   Z - any digit from 1-9
//   N - any digit from 2-9
//   [1235-9] - any digit in the brackets (in this example, 1,2,3,5,6,7,8,9)
//   . - wildcard, matches anything remaining (e.g. _9011. matches
//	anything starting with 9011 excluding 9011 itself)
//   ! - wildcard, causes the matching process to complete as soon as
//       it can unambiguously determine that no other matches are possible
//
// For example the extension _NXXXXXX would match normal 7 digit dialings,
// while _1NXXNXXXXXX would represent an area code plus phone number
// preceded by a one.
//
// Each step of an extension is ordered by priority, which must
// always start with 1 to be considered a valid extension.  The priority
// "next" or "n" means the previous priority plus one, regardless of whether
// the previous priority was associated with the current extension or not.
// The priority "same" or "s" means the same as the previously specified
// priority, again regardless of whether the previous entry was for the
// same extension.  Priorities may be immediately followed by a plus sign
// and another integer to add that amount (most useful with 's' or 'n').
// Priorities may then also have an alias, or label, in
// parenthesis after their name which can be used in goto situations
//
// Contexts contain several lines, one for each step of each
// extension, which can take one of two forms as listed below,
// with the first form being preferred.  One may include another
// context in the current one as well, optionally with a
// date and time.  Included contexts are included in the order
// they are listed.
//
//context name {
//	exten-name => {
//		application(arg1,arg2,...);
//
// 	Timing list for includes is
//
//   <time range>|<days of week>|<days of month>|<months>
//
//	includes {
//		daytime|9:00-17:00|mon-fri|*|*;
//      };
//
// 	ignorepat can be used to instruct drivers to not cancel dialtone upon
// 	receipt of a particular pattern.  The most commonly used example is
// 	of course '9' like this:
//
//	ignorepat => 9;
//
// 	so that dialtone remains even after dialing a 9.
//};


//
// Sample entries for extensions.conf
//
//
context ael-dundi-e164-canonical {
	//
	// List canonical entries here
	//
	// 12564286000 => &ael-std-exten(6000,IAX2/foo);
	// _125642860XX => Dial(IAX2/otherbox/${EXTEN:7});
};

context ael-dundi-e164-customers {
	//
	// If you are an ITSP or Reseller, list your customers here.
	//
	//_12564286000 => Dial(SIP/customer1);
	//_12564286001 => Dial(IAX2/customer2);
};

context ael-dundi-e164-via-pstn {
	//
	// If you are freely delivering calls to the PSTN, list them here
	//
	//_1256428XXXX => Dial(DAHDI/G2/${EXTEN:7}); // Expose all of 256-428
	//_1256325XXXX => Dial(DAHDI/G2/${EXTEN:7}); // Ditto for 256-325
};

context ael-dundi-e164-local {
	//
	// Context to put your dundi IAX2 or SIP user in for
	// full access
	//
	includes {
	 ael-dundi-e164-canonical;
	 ael-dundi-e164-customers;
	 ael-dundi-e164-via-pstn;
	};
};

context ael-dundi-e164-switch {
	//
	// Just a wrapper for the switch
	//

	switches {
		DUNDi/e164;
	};
};

context ael-dundi-e164-lookup {
	//
	// Locally to lookup, try looking for a local E.164 solution
	// then try DUNDi if we don't have one.
	//
	includes {
		ael-dundi-e164-local;
		ael-dundi-e164-switch;
	};
	//
};

//
// DUNDi can also be implemented as a Macro instead of using
// the Local channel driver.
//
macro ael-dundi-e164(exten) {
//
// ARG1 is the extension to Dial
//
	goto ${exten}|1;
	return;
};

//
// The SWITCH statement permits a server to share the dialplan with
// another server. Use with care: Reciprocal switch statements are not
// allowed (e.g. both A -> B and B -> A), and the switched server needs
// to be on-line or else dialing can be severely delayed.
//
context ael-iaxprovider {
	switches {
	// IAX2/user:[key]@myserver/mycontext;
	};
};

context ael-trunkint {
	//
	// International long distance through trunk
	//
	includes {
		ael-dundi-e164-lookup;
	};
	_9011. => {
		&ael-dundi-e164(${EXTEN:4});
		Dial(${OUTBOUND-TRUNK}/${EXTEN:${OUTBOUND-TRUNKMSD}});
	};
};

context ael-trunkld {
	//
	// Long distance context accessed through trunk
	//
	includes {
		ael-dundi-e164-lookup;
	};
	_91NXXNXXXXXX => {
		&ael-dundi-e164(${EXTEN:1});
		Dial(${OUTBOUND-TRUNK}/${EXTEN:${OUTBOUND-TRUNKMSD}});
	};
};

context ael-trunklocal {
	//
	// Local seven-digit dialing accessed through trunk interface
	//
	_9NXXXXXX => {
		Dial(${OUTBOUND-TRUNK}/${EXTEN:${OUTBOUND-TRUNKMSD}});
	};
};

context ael-trunktollfree {
	//
	// Long distance context accessed through trunk interface
	//

	_91800NXXXXXX => Dial(${OUTBOUND-TRUNK}/${EXTEN:${OUTBOUND-TRUNKMSD}});
	_91888NXXXXXX => Dial(${OUTBOUND-TRUNK}/${EXTEN:${OUTBOUND-TRUNKMSD}});
	_91877NXXXXXX => Dial(${OUTBOUND-TRUNK}/${EXTEN:${OUTBOUND-TRUNKMSD}});
	_91866NXXXXXX => Dial(${OUTBOUND-TRUNK}/${EXTEN:${OUTBOUND-TRUNKMSD}});
};

context ael-international {
	//
	// Master context for international long distance
	//
	ignorepat => 9;
	includes {
		ael-longdistance;
		ael-trunkint;
	};
};

context ael-longdistance {
	//
	// Master context for long distance
	//
	ignorepat => 9;
	includes {
		ael-local;
		ael-trunkld;
	};
};

context ael-local {
	//
	// Master context for local and toll-free calls only
	//
	ignorepat => 9;
	includes {
		ael-default;
		ael-trunklocal;
		ael-trunktollfree;
		ael-iaxprovider;
	};
};

//
// You can use an alternative switch type as well, to resolve
// extensions that are not known here, for example with remote
// IAX switching you transparently get access to the remote
// Asterisk PBX
//
// switch => IAX2/user:password@bigserver/local
//
// An "lswitch" is like a switch but is literal, in that
// variable substitution is not performed at load time
// but is passed to the switch directly (presumably to
// be substituted in the switch routine itself)
//
// lswitch => Loopback/12${EXTEN}@othercontext
//
// An "eswitch" is like a switch but the evaluation of
// variable substitution is performed at runtime before
// being passed to the switch routine.
//
// eswitch => IAX2/context@${CURSERVER}


macro ael-std-exten-ael( ext , dev ) {
        Dial(${dev}/${ext},20);
        switch(${DIALSTATUS}) {
        case BUSY:
                Voicemail(${ext},b);
                break;
        default:
                Voicemail(${ext},u);
        };
        catch a {
                VoiceMailMain(${ext});
                return;
        };
	return;
};

context ael-demo {
	s => {
		Wait(1);
		Answer();
		Set(TIMEOUT(digit)=5);
		Set(TIMEOUT(response)=10);
restart:
		Background(demo-congrats);
instructions:
		for (x=0; ${x} < 3; x=${x} + 1) {
			Background(demo-instruct);
			WaitExten();
		};
	};
	2 => {
		Background(demo-moreinfo);
		goto s|instructions;
	};
	3 => {
		Set(LANGUAGE()=fr);
		goto s|restart;
	};
	1000 => {
		goto ael-default|s|1;
	};
	500 => {
		Playback(demo-abouttotry);
		Dial(IAX2/guest@misery.digium.com/s@default);
		Playback(demo-nogo);
		goto s|instructions;
	};
	600 => {
		Playback(demo-echotest);
		Echo();
		Playback(demo-echodone);
		goto s|instructions;
	};
	_1234 => &ael-std-exten-ael(${EXTEN}, "IAX2");
	8500 => {
		VoicemailMain();
		goto s|instructions;
	};
	# => {
		Playback(demo-thanks);
		Hangup();
	};
	t => goto #|1;
	i => Playback(invalid);
};


//
// If you wish to use AEL for your default context, remove it
// from extensions.conf (or change its name or comment it out)
// and then uncomment the one here.
//

context ael-default {

// By default we include the demo.  In a production system, you
// probably don't want to have the demo there.

	includes {
		ael-demo;
	};
//
// Extensions like the two below can be used for FWD, Nikotel, sipgate etc.
// Note that you must have a [sipprovider] section in sip.conf whereas
// the otherprovider.net example does not require such a peer definition
//
//_41X. => Dial(SIP/${EXTEN:2}@sipprovider,,r);
//_42X. => Dial(SIP/user:passwd@${EXTEN:2}@otherprovider.net,30,rT);

// Real extensions would go here. Generally you want real extensions to be
// 4 or 5 digits long (although there is no such requirement) and start with a
// single digit that is fairly large (like 6 or 7) so that you have plenty of
// room to overlap extensions and menu options without conflict.  You can alias
// them with names, too, and use global variables

// 6245  => {
//		hint(SIP/Grandstream1&SIP/Xlite1,Joe Schmoe); // Channel hints for presence
// 		Dial(SIP/Grandstream1,20,rt);                 // permit transfer
//        Dial(${HINT}/5245},20,rtT);                    // Use hint as listed
//        switch(${DIALSTATUS}) {
//        case BUSY:
//                Voicemail(6245,b);
//				return;
//        default:
//                Voicemail(6245,u);
//				return;
//        };
//       };

// 6361 => Dial(IAX2/JaneDoe,,rm);                // ring without time limit
// 6389 => Dial(MGCP/aaln/1@192.168.0.14);
// 6394 => Dial(Local/6275/n);                    // this will dial ${MARK}

// 6275 => &ael-stdexten(6275,${MARK});           // assuming ${MARK} is something like DAHDI/2
// mark => goto 6275|1;                          // alias mark to 6275
// 6536 => &ael-stdexten(6236,${WIL});            // Ditto for wil
// wil  => goto 6236|1;
//
// Some other handy things are an extension for checking voicemail via
// voicemailmain
//
// 8500 => {
//			VoicemailMain();
//			Hangup();
//	       };
//
// Or a conference room (you'll need to edit meetme.conf to enable this room)
//
// 8600 => Meetme(1234);
//
// Or playing an announcement to the called party, as soon it answers
//
// 8700 => Dial(${MARK},30,A(/path/to/my/announcemsg))
//
// For more information on applications, just type "show applications" at your
// friendly Asterisk CLI prompt.
//
// 'show application <command>' will show details of how you
// use that particular application in this file, the dial plan.
//
}

######################################################################
# FILE: /etc/asterisk/modules.conf
######################################################################
;
; Asterisk configuration file
;
; Module Loader configuration file
;

[modules]
autoload=yes
;
; Any modules that need to be loaded before the Asterisk core has been
; initialized (just after the logger initialization) can be loaded
; using 'preload'.  'preload' forces a module and the modules it
; is known to depend upon to be loaded earlier than they normally get
; loaded.
;
; NOTE: There is no good reason left to use 'preload' anymore.  It was
; historically required to preload realtime driver modules so you could
; map Asterisk core configuration files to Realtime storage.
; This is no longer needed.
;
;preload = your_special_module.so
;
; If you want Asterisk to fail if a module does not load, then use
; the "require" keyword. Asterisk will exit with a status code of 2
; if a required module does not load.
;
;require = chan_pjsip.so
;
; If you want you can combine with preload
; preload-require = your_special_module.so
;
;load = res_musiconhold.so
;
; Load one of: alsa, or console (portaudio).
; By default, load chan_console only (automatically).
;
noload = chan_alsa.so
;noload = chan_console.so
;
; Do not load res_hep and kin unless you are using HEP monitoring
; <http://sipcapture.org> in your network.
;
noload = res_hep.so
noload = res_hep_pjsip.so
noload = res_hep_rtcp.so
;
; Do not load chan_sip by default, it may conflict with res_pjsip.
noload = chan_sip.so
;
; Load one of the voicemail modules as they are mutually exclusive.
; By default, load app_voicemail only (automatically).
;
;noload = app_voicemail.so
noload = app_voicemail_imap.so
noload = app_voicemail_odbc.so

######################################################################
# FILE: /etc/asterisk/fax.conf
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /etc/asterisk/rtp.conf
######################################################################
;
; RTP Configuration
;
;[general]
;
; RTP start and RTP end configure start and end addresses
;
; Defaults are rtpstart=5000 and rtpend=31000
;
;rtpstart=10000
;rtpend=20000
[general]
rtpstart=12000
rtpend=12049
icesupport=no
strictrtp=yes


;
; Whether to enable or disable UDP checksums on RTP traffic
;
;rtpchecksums=no
;
; The amount of time a DTMF digit with no 'end' marker should be
; allowed to continue (in 'samples', 1/8000 of a second)
;
;dtmftimeout=3000
; rtcpinterval = 5000 	; Milliseconds between rtcp reports
			;(min 500, max 60000, default 5000)
;
; Enable strict RTP protection.  This will drop RTP packets that do not come
; from the recognized source of the RTP stream.  Strict RTP qualifies RTP
; packet stream sources before accepting them upon initial connection and
; when the connection is renegotiated (e.g., transfers and direct media).
; Initial connection and renegotiation starts a learning mode to qualify
; stream source addresses.  Once Asterisk has recognized a stream it will
; allow other streams to qualify and replace the current stream for 5
; seconds after starting learning mode.  Once learning mode completes the
; current stream is locked in and cannot change until the next
; renegotiation.
; Valid options are "no" to disable strictrtp, "yes" to enable strictrtp,
; and "seqno", which does the same thing as strictrtp=yes, but only checks
; to make sure the sequence number is correct rather than checking the time
; interval as well.
; This option is enabled by default.
; strictrtp=yes
;
; Number of packets containing consecutive sequence values needed
; to change the RTP source socket address. This option only comes
; into play while using strictrtp=yes. Consider changing this value
; if rtp packets are dropped from one or both ends after a call is
; connected. This option is set to 4 by default.
; probation=8
;
; Enable sRTP replay protection. Buggy SIP user agents (UAs) reset the
; sequence number (RTP-SEQ) on a re-INVITE, for example, with Session Timers
; or on Call Hold/Resume, but keep the synchronization source (RTP-SSRC). If
; the new RTP-SEQ is higher than the previous one, the call continues if the
; roll-over counter (sRTP-ROC) is zero (the call lasted less than 22 minutes).
; In all other cases, the call faces one-way audio or even no audio at all.
; "replay check failed (index too old)" gets printed continuously. This is a
; software bug. You have to report this to the creator of that UA. Until it is
; fixed, you could disable sRTP replay protection (see RFC 3711 section 3.3.2).
; This option is enabled by default.
; srtpreplayprotection=yes
;
; Whether to enable or disable ICE support. This option is enabled by default.
; icesupport=false
;
; Hostname or address for the STUN server used when determining the external
; IP address and port an RTP session can be reached at. The port number is
; optional. If omitted the default value of 3478 will be used. This option is
; disabled by default. Name resolution will occur at load time, and if DNS is
; used, name resolution will occur repeatedly after the TTL expires.
;
; e.g. stunaddr=mystun.server.com:3478
;
; stunaddr=
;
; Some multihomed servers have IP interfaces that cannot reach the STUN
; server specified by stunaddr.  Blacklist those interface subnets from
; trying to send a STUN packet to find the external IP address.
; Attempting to send the STUN packet needlessly delays processing incoming
; and outgoing SIP INVITEs because we will wait for a response that can
; never come until we give up on the response.
; * Multiple subnets may be listed.
; * Blacklisting applies to IPv4 only.  STUN isn't needed for IPv6.
; * Blacklisting applies when binding RTP to specific IP addresses and not
; the wildcard 0.0.0.0 address.  e.g., A PJSIP endpoint binding RTP to a
; specific address using the bind_rtp_to_media_address and media_address
; options.  Or the PJSIP endpoint specifies an explicit transport that binds
; to a specific IP address.  Blacklisting is done via ACL infrastructure
; so it's possible to whitelist as well.
;
; stun_acl = named_acl
; stun_deny = 0.0.0.0/0
; stun_permit = 1.2.3.4/32
;
; For historic reasons stun_blacklist is an alias for stun_deny.
;
; Whether to report the PJSIP version in a SOFTWARE attribute for all
; outgoing STUN packets. This option is enabled by default.
;
; stun_software_attribute=yes
;
; Hostname or address for the TURN server to be used as a relay. The port
; number is optional. If omitted the default value of 3478 will be used.
; This option is disabled by default.
;
; e.g. turnaddr=myturn.server.com:34780
;
; turnaddr=
;
; Username used to authenticate with TURN relay server.
; turnusername=
;
; Password used to authenticate with TURN relay server.
; turnpassword=
;
; An ACL can be used to determine which discovered addresses to include for
; ICE, srflx and relay discovery.  This is useful to optimize the ICE process
; where a system has multiple host address ranges and/or physical interfaces
; and certain of them are not expected to be used for RTP. For example, VPNs
; and local interconnections may not be suitable or necessary for ICE. Multiple
; subnets may be listed. If left unconfigured, all discovered host addresses
; are used.
;
; ice_acl = named_acl
; ice_deny = 0.0.0.0/0
; ice_permit = 1.2.3.4/32
;
; For historic reasons ice_blacklist is an alias for ice_deny.
;
; The MTU to use for DTLS packet fragmentation. This option is set to 1200
; by default. The minimum MTU is 256.
; dtls_mtu = 1200
;
[ice_host_candidates]
;
; When Asterisk is behind a static one-to-one NAT and ICE is in use, ICE will
; expose the server's internal IP address as one of the host candidates.
; Although using STUN (see the 'stunaddr' configuration option) will provide a
; publicly accessible IP, the internal IP will still be sent to the remote
; peer. To help hide the topology of your internal network, you can override
; the host candidates that Asterisk will send to the remote peer.
;
; IMPORTANT: Only use this functionality when your Asterisk server is behind a
; one-to-one NAT and you know what you're doing. If you do define anything
; here, you almost certainly will NOT want to specify 'stunaddr' or 'turnaddr'
; above.
;
; The format for these overrides is:
;
;    <local address> => <advertised address>,[include_local_address]
;
; The following will replace 192.168.1.10 with 1.2.3.4 during ICE
; negotiation:
;
;192.168.1.10 => 1.2.3.4
;
; The following will include BOTH 192.168.1.10 and 1.2.3.4 during ICE
; negotiation instead of replacing 192.168.1.10.  This can make it easier
; to serve both local and remote clients.
;
;192.168.1.10 => 1.2.3.4,include_local_address
;
; You can define an override for more than 1 interface if you have a multihomed
; server. Any local interface that is not matched will be passed through
; unaltered. Both IPv4 and IPv6 addresses are supported.

######################################################################
# FILE: /etc/asterisk/asterisk.conf
######################################################################
; In order for Asterisk to process the [directories](!) stanza below,
; you will need to remove the (!) suffix, which marks this as a template.
; The compiled-in defaults are typically sufficient, so most users will 
; not have to do this.
[directories](!)
astcachedir => /var/cache/asterisk
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
astsbindir => /usr/sbin

[options]
;verbose = 3
;debug = 3
;trace = 0              ; Set the trace level.
;refdebug = yes			; Enable reference count debug logging.
;alwaysfork = yes		; Same as -F at startup.
;nofork = yes			; Same as -f at startup.
;quiet = yes			; Same as -q at startup.
;timestamp = yes		; Same as -T at startup.
;execincludes = yes		; Support #exec in config files.
;console = yes			; Run as console (same as -c at startup).
;highpriority = yes		; Run realtime priority (same as -p at
				; startup).
;initcrypto = yes		; Initialize crypto keys (same as -i at
				; startup).
;nocolor = yes			; Disable console colors.
;dontwarn = yes			; Disable some warnings.
;dumpcore = yes			; Dump core on crash (same as -g at startup).
;languageprefix = yes		; Use the new sound prefix path syntax.
;systemname = my_system_name	; Prefix uniqueid with a system name for
				; Global uniqueness issues.
;autosystemname = yes		; Automatically set systemname to hostname,
				; uses 'localhost' on failure, or systemname if
				; set.
;mindtmfduration = 80		; Set minimum DTMF duration in ms (default 80 ms)
				; If we get shorter DTMF messages, these will be
				; changed to the minimum duration
;maxcalls = 10			; Maximum amount of calls allowed.
;maxload = 0.9			; Asterisk stops accepting new calls if the
				; load average exceed this limit.
;maxfiles = 1000		; Maximum amount of openfiles.
;minmemfree = 1			; In MBs, Asterisk stops accepting new calls if
				; the amount of free memory falls below this
				; watermark.
;cache_media_frames = yes	; Cache media frames for performance
				; Disable this option to help track down media frame
				; mismanagement when using valgrind or MALLOC_DEBUG.
				; The cache gets in the way of determining if the
				; frame is used after being freed and who freed it.
				; NOTE: This option has no effect when Asterisk is
				; compiled with the LOW_MEMORY compile time option
				; enabled because the cache code does not exist.
				; Default yes
;cache_record_files = yes	; Cache recorded sound files to another
				; directory during recording.
;record_cache_dir = /tmp	; Specify cache directory (used in conjunction
				; with cache_record_files).
;transmit_silence = yes		; Transmit silence while a channel is in a
				; waiting state, a recording only state, or
				; when DTMF is being generated.  Note that the
				; silence internally is generated in raw signed
				; linear format. This means that it must be
				; transcoded into the native format of the
				; channel before it can be sent to the device.
				; It is for this reason that this is optional,
				; as it may result in requiring a temporary
				; codec translation path for a channel that may
				; not otherwise require one.
;transcode_via_sln = yes	; Build transcode paths via SLINEAR, instead of
				; directly.
;runuser = asterisk		; The user to run as.
;rungroup = asterisk		; The group to run as.
;lightbackground = yes		; If your terminal is set for a light-colored
				; background.
;forceblackbackground = yes     ; Force the background of the terminal to be
                                ; black, in order for terminal colors to show
                                ; up properly.
;defaultlanguage = en           ; Default language
documentation_language = en_US	; Set the language you want documentation
				; displayed in. Value is in the same format as
				; locale names.
;hideconnect = yes		; Hide messages displayed when a remote console
				; connects and disconnects.
;lockconfdir = no		; Protect the directory containing the
				; configuration files (/etc/asterisk) with a
				; lock.
;stdexten = gosub		; How to invoke the extensions.conf stdexten.
				; macro - Invoke the stdexten using a macro as
				;         done by legacy Asterisk versions.
				; gosub - Invoke the stdexten using a gosub as
				;         documented in extensions.conf.sample.
				; Default gosub.
;live_dangerously = no		; Enable the execution of 'dangerous' dialplan
				; functions and configuration file access from
				; external sources (AMI, etc.) These functions
				; (such as SHELL) are considered dangerous
				; because they can allow privilege escalation.
				; Configuration files are considered dangerous
				; if they exist outside of the Asterisk
				; configuration directory.
				; Default no
;entityid=00:11:22:33:44:55	; Entity ID.
				; This is in the form of a MAC address.
				; It should be universally unique.
				; It must be unique between servers communicating
				; with a protocol that uses this value.
				; This is currently is used by DUNDi and
				; Exchanging Device and Mailbox State
				; using protocols: XMPP, Corosync and PJSIP.
;rtp_use_dynamic = yes          ; When set to "yes" RTP dynamic payload types
                                ; are assigned dynamically per RTP instance vs.
                                ; allowing Asterisk to globally initialize them
                                ; to pre-designated numbers (defaults to "yes").
;rtp_pt_dynamic = 35		; Normally the Dynamic RTP Payload Type numbers
				; are 96-127, which allow just 32 formats. The
				; starting point 35 enables the range 35-63 and
				; allows 29 additional formats. When you use
				; more than 32 formats in the dynamic range and
				; calls are not accepted by a remote
				; implementation, please report this and go
				; back to value 96.
;hide_messaging_ami_events = no;  This option, if enabled, will
                ; suppress all of the Message/ast_msg_queue channel's
                ; housekeeping AMI and ARI channel events.  This can
                ; reduce the load on the manager and ARI applications
                ; when the Digium Phone Module for Asterisk is in use.
;sounds_search_custom_dir = no;  This option, if enabled, will
                ; cause Asterisk to search for sounds files in
                ; AST_DATA_DIR/sounds/custom before searching the
                ; normal directories like AST_DATA_DIR/sounds/<lang>.
;channel_storage_backend = ao2_legacy ; Select the channel storage backend
                ; to use for live operation.
                ;   ao2_legacy:  Original implementation (default)
                ; Depending on compile options, the following may also be
                ; available:
                ;   cpp_map_name_id: Use C++ Maps to index both
                ;                    channel name and channel uniqueid.
                ; See http://s.asterisk.net/dc679ec3 for more information.
;disable_remote_console_shell = no; Prevent remote console CLI sessions
                ; from executing shell commands with the '!' prefix.
                ; Default: no

; Changing the following lines may compromise your security.
;[files]
;astctlpermissions = 0660
;astctlowner = root
;astctlgroup = apache
;astctl = asterisk.ctl

######################################################################
# FILE: /etc/asterisk/logger.conf
######################################################################
;
; Logging Configuration
;
; In this file, you configure logging to files or to
; the syslog system.
;
; "logger reload" at the CLI will reload configuration
; of the logging system.

[general]
;
; Customize the display of debug message time stamps
; this example is the ISO 8601 date format (yyyy-mm-dd HH:MM:SS)
;
; see strftime(3) Linux manual for format specifiers.  Note that there is also
; a fractional second parameter which may be used in this field.  Use %1q
; for tenths, %2q for hundredths, etc.
;
;dateformat=%F %T       ; ISO 8601 date format
;dateformat=%F %T.%3q   ; with milliseconds
;
;
; This makes Asterisk write callids to log messages
; (defaults to yes)
;use_callids = no
;
; This appends the hostname to the name of the log files.
;appendhostname = yes
;
; This determines whether or not we log queue events to a file
; (defaults to yes).
;queue_log = no
;
; Determines whether the queue_log always goes to a file, even
; when a realtime backend is present (defaults to no).
;queue_log_to_file = yes
;
; Set the queue_log filename
; (defaults to queue_log)
;queue_log_name = queue_log
;
; When using realtime for the queue log, use GMT for the timestamp
; instead of localtime.  The default of this option is 'no'.
;queue_log_realtime_use_gmt = yes
;
; Log rotation strategy:
; none:  Do not perform any logrotation at all.  You should make
;        very sure to set up some external logrotate mechanism
;        as the asterisk logs can get very large, very quickly.
; sequential:  Rename archived logs in order, such that the newest
;              has the highest sequence number [default].  When
;              exec_after_rotate is set, ${filename} will specify
;              the new archived logfile.
; rotate:  Rotate all the old files, such that the oldest has the
;          highest sequence number [this is the expected behavior
;          for Unix administrators].  When exec_after_rotate is
;          set, ${filename} will specify the original root filename.
; timestamp:  Rename the logfiles using a timestamp instead of a
;             sequence number when "logger rotate" is executed.
;             When exec_after_rotate is set, ${filename} will
;             specify the new archived logfile.
;rotatestrategy = rotate
;
; Run a system command after rotating the files.  This is mainly
; useful for rotatestrategy=rotate. The example allows the last
; two archive files to remain uncompressed, but after that point,
; they are compressed on disk.
;
; exec_after_rotate=gzip -9 ${filename}.2
;
;
; For each file, specify what to log.
;
; For console logging, you set options at start of
; Asterisk with -v for verbose and -d for debug
; See 'asterisk -h' for more information.
;
; Directory for log files is configures in asterisk.conf
; option astlogdir
;
; All log messages go to a queue serviced by a single thread
; which does all the IO.  This setting controls how big that
; queue can get (and therefore how much memory is allocated)
; before new messages are discarded.
; The default is 1000
;logger_queue_limit = 250
;
; Any custom logging levels you may want to use, which can then
; be sent to logging channels. The maximum number of custom
; levels is 16, but not all of these may be available if modules
; in Asterisk define their own.
;custom_levels = foobar,important,compliance
;
[logfiles]
;
; Format is:
;
; logger_name => [formatter]levels
;
; The name of the logger dictates not only the name of the logging
; channel, but also its type. Valid types are:
;   - 'console'  - The root console of Asterisk
;   - 'syslog'   - Linux syslog, with facilities specified afterwards with
;                  a period delimiter, e.g., 'syslog.local0'
;   - 'filename' - The name of the log file to create. This is the default
;                  for log channels.
;
; Filenames can either be relative to the standard Asterisk log directory
; (see 'astlogdir' in asterisk.conf), or absolute paths that begin with
; '/'.
;
; An optional formatter can be specified prior to the log levels sent
; to the log channel. The formatter is defined immediately preceeding the
; levels, and is enclosed in square brackets. Valid formatters are:
;   - [default] - The default formatter, this outputs log messages using a
;                 human readable format.
;   - [plain]   - The plain formatter, this outputs log messages using a
;                 human readable format with the addition of function name
;                 and line number. No color escape codes are ever printed
;                 nor are verbose messages treated specially.
;   - [json]    - Log the output in JSON. Note that JSON formatted log entries,
;                 if specified for a logger type of 'console', will be formatted
;                 per the 'default' formatter for log messages of type VERBOSE.
;                 This is due to the remote consoles interpreting verbosity
;                 outside of the logging subsystem.
;
; Log levels include the following, and are specified in a comma delineated
; list:
;    debug
;    trace
;    notice
;    warning
;    error
;    verbose(<level>)
;    dtmf
;    fax
;    security
;    <customlevel>
;
; Verbose takes an optional argument, in the form of an integer level. The
; verbose level can be set per logfile. Verbose messages with higher levels
; will not be logged to the file.  If the verbose level is not specified, it
; will log verbose messages following the current level of the root console.
;
; Debug has multiple levels like verbose. However, it is a system wide setting
; and cannot be specified per logfile. You specify the debug level elsewhere
; such as the CLI 'core set debug 3', starting Asterisk with '-ddd', or in
; asterisk.conf 'debug=3'.
;
; Special level name "*" means all levels, even dynamic levels registered
; by modules after the logger has been initialized (this means that loading
; and unloading modules that create/remove dynamic logger levels will result
; in these levels being included on filenames that have a level name of "*",
; without any need to perform a 'logger reload' or similar operation).
; Note that there is no value in specifying both "*" and specific level names
; for a filename; the "*" level means all levels.  The only exception is if
; you need to specify a specific verbose level. e.g, "verbose(3),*".
;
; We highly recommend that you DO NOT turn on debug mode if you are simply
; running a production system.  Debug mode turns on a LOT of extra messages,
; most of which you are unlikely to understand without an understanding of
; the underlying code.  Do NOT report debug messages as code issues, unless
; you have a specific issue that you are attempting to debug.  They are
; messages for just that -- debugging -- and do not rise to the level of
; something that merit your attention as an Asterisk administrator.  Both
; debug and trace messages are also very verbose and can and do fill up
; logfiles quickly.  This is another reason not to have debug or trace
; modes on a production system unless you are in the process of debugging
; a specific issue.
;
;debug.log => error,warning,notice,verbose,debug
;trace.log => trace
;security.log => security
console => notice,warning,error
;console => notice,warning,error,debug
messages.log => notice,warning,error
;full.log => notice,warning,error,debug,verbose,dtmf,fax
;
;full-json.log => [json]debug,verbose,notice,warning,error,dtmf,fax
;
;syslog keyword : This special keyword logs to syslog facility
;
;syslog.local0 => notice,warning,error
;
; A log level defined in 'custom_levels' above
;important.log = important

######################################################################
# FILE: /etc/asterisk/iax.conf
######################################################################
[general]
bindport=4569
bindaddr=0.0.0.0
; wichtig für lokale Tests:
delayreject=yes

[iaxmodem0]
type=friend
username=iaxmodem0
secret=faxsecret
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
secret=faxsecret
host=dynamic
context=fax-out
auth=md5
disallow=all
allow=alaw
requirecalltoken=no
jitterbuffer=no
forcejitterbuffer=no

######################################################################
# FILE: /etc/hylafax/hyla.conf
######################################################################
#
#	/etc/hylafax/hyla.conf
#
#	System-wide client configuration file


# System-wide configuration information
# -------------------------------------

# Host - host to contact for service
#
Host:			localhost

# Verbose - whether or not to enable protocol tracing
#
Verbose:		No


# Faxstat configuration information
# ---------------------------------

# TimeZone - control whether the times and dates are reported in the local
#	     timezone of the server (`local') or in GMT (`GMT').
#
TimeZone:		local


# Sendfax configuration information
# ---------------------------------

# DialRules - file containing dialstring rules
#
DialRules: 		"/etc/hylafax/dialrules"

# If you don't want to have cover pages added automatically for every fax send
# by "sendfax", please uncomment the following line. 

# AutoCoverPage:          No

# These are Fontmap sources in various Debian and Ubuntu releases.
# etch: /usr/share/gs-afpl/8.53/lib:/usr/share/gs-esp/8.15/lib
# lenny: /usr/share/ghostscript/8.62/lib
# squeeze: /usr/share/ghostscript/8.71/Resource/Init
# defoma (all Debian versions and Ubuntu): /var/lib/defoma/gs.d/dirs/fonts

FontMap:  /var/lib/defoma/gs.d/dirs/fonts:/usr/share/ghostscript/8.71/Resource/Init:/usr/share/ghostscript/8.62/lib:/usr/share/gs-afpl/8.53/lib:/usr/share/gs-esp/8.15/lib
FontPath: /usr/share/fonts/type1/gsfonts


######################################################################
# FILE: /etc/hylafax/FaxDispatch
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /etc/hylafax/hosts.hfaxd
######################################################################
# hosts.hfaxd
# This file contains permissions and password for every user in
# the system.
#
# For more information on this biject, please see its man page
# and the commands faxadduser and faxdeluser.
localhost:21::

######################################################################
# FILE: /var/spool/hylafax/etc/config.ttyIAX0
######################################################################
CountryCode:             49
AreaCode:                2331
LongDistancePrefix:      0
InternationalPrefix:     00
DialStringRules:         etc/dialrules
NoDialToneDetection:     true
ECMEnable:               false
MaxRecvRate: 9600
MaxSendRate: 9600
ECM: No



ServerTracing:           0xFFF
SessionTracing:          0xFFF

RingsBeforeAnswer:       1

ModemType:               Class1
ModemRate:               9600
ModemFlowControl:        none

ModemResetCmds:          ATZ
ModemReadyCmd:           AT
ModemAnswerCmd:          ATA
ModemDialCmd:            ATDT%s

GettyArgs:               "-h %l dx_%s"


RecvFileMode:            0600
LogFileMode:             0600



######################################################################
# FILE: /var/spool/hylafax/etc/config.ttyIAX1
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /var/spool/hylafax/etc/config.ttyACM0
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /var/spool/hylafax/etc/config.modem
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /var/spool/hylafax/etc/setup.cache
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /etc/iaxmodem/iaxmodem.conf
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /etc/default/iaxmodem
######################################################################
# (nicht vorhanden oder nicht lesbar)

######################################################################
# FILE: /etc/init.d/iaxmodem
######################################################################
#! /bin/sh
#
### BEGIN INIT INFO
# Provides:          iaxmodem
# Required-Start:    $syslog $remote_fs $network
# Required-Stop:     $syslog $remote_fs $network
# Should-Start:      asterisk
# Should-Stop:       asterisk
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Software modem with IAX2 connectivity
# Description:       Use this software modem with Asterisk or another
#                    IPBX with IAX2 connectivity to send and receive
#                    faxes over VoIP.
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=/usr/bin/iaxmodem
NAME=iaxmodem
DESC=iaxmodem

. /lib/lsb/init-functions

test -x $DAEMON || exit 0

PIDFILE=/run/$NAME.pid

set -e

case "$1" in
  start)
	echo -n "Starting $DESC: "
	start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON --test > /dev/null \
	    || exit 1

	start-stop-daemon --start --quiet --pidfile  $PIDFILE \
		--exec $DAEMON
	echo "$NAME."
	;;
  stop)
	echo -n "Stopping $DESC: "
	start-stop-daemon --stop --quiet --oknodo --pidfile $PIDFILE \
		--exec $DAEMON
	echo "$NAME."
	;;
  reload)
	echo -n "Reloading $DESC: "
	if [ -e $PIDFILE ]; then
	    kill -HUP $(cat $PIDFILE)
	    echo "$NAME."
	else
	    echo "$NAME not running!"
	    exit 1
	fi
	;;
  restart|force-reload)
	echo -n "Restarting $DESC: "
	start-stop-daemon --stop --quiet --pidfile \
		$PIDFILE --exec $DAEMON
	sleep 1
	start-stop-daemon --start --quiet --pidfile \
		$PIDFILE --exec $DAEMON -- $DAEMON_OPTS
	echo "$NAME."
	;;
  status)
	if [ -s $PIDFILE ]; then
	    RUNNING=$(cat $PIDFILE)
	    if [ -d /proc/$RUNNING ]; then
		if [ $(readlink /proc/$RUNNING/exe) = $DAEMON ]; then
		    echo "$NAME is running."
		    exit 0
		fi
	    fi

	    # No such PID, or executables don't match
	    echo "$NAME is not running, but pidfile existed."
	    rm $PIDFILE
	    exit 1
	else
	    rm -f $PIDFILE
	    echo "$NAME not running."
	    exit 1
	fi
	;;
  *)
	N=/etc/init.d/$NAME
	echo "Usage: $N {start|stop|restart|reload|force-reload|status}" >&2
	exit 1
	;;
esac

exit 0

######################################################################
# SYSTEMD UNIT: asterisk.service
######################################################################
# /run/systemd/generator.late/asterisk.service
# Automatically generated by systemd-sysv-generator

[Unit]
Documentation=man:systemd-sysv-generator(8)
SourcePath=/etc/init.d/asterisk
Description=LSB: Asterisk PBX
Before=multi-user.target
Before=multi-user.target
Before=multi-user.target
Before=graphical.target
After=network-online.target
After=nss-lookup.target
After=remote-fs.target
After=dahdi.service
After=misdn.service
After=lcr.service
After=wanrouter.service
After=mysql.service
After=postgresql.service
Wants=network-online.target

[Service]
Type=forking
Restart=no
TimeoutSec=5min
IgnoreSIGPIPE=no
KillMode=process
GuessMainPID=no
RemainAfterExit=yes
SuccessExitStatus=5 6
ExecStart=/etc/init.d/asterisk start
ExecStop=/etc/init.d/asterisk stop
ExecReload=/etc/init.d/asterisk reload

######################################################################
# SYSTEMD UNIT: hylafax.service
######################################################################
# /usr/lib/systemd/system/hylafax.service
# This service hide SysV init script with same name.
# Il also groups hfaxd and faxq services together.

[Unit]
Description=HylaFAX
Documentation=man:hylafax

[Service]
Type=oneshot
ExecStart=/bin/true
ExecReload=/bin/true
RemainAfterExit=on

[Install]
WantedBy=multi-user.target

######################################################################
# SYSTEMD UNIT: iaxmodem.service
######################################################################
# /run/systemd/generator.late/iaxmodem.service
# Automatically generated by systemd-sysv-generator

[Unit]
Documentation=man:systemd-sysv-generator(8)
SourcePath=/etc/init.d/iaxmodem
Description=LSB: Software modem with IAX2 connectivity
After=remote-fs.target
After=network-online.target
After=asterisk.service
Wants=network-online.target

[Service]
Type=forking
Restart=no
TimeoutSec=5min
IgnoreSIGPIPE=no
KillMode=process
GuessMainPID=no
RemainAfterExit=yes
SuccessExitStatus=5 6
ExecStart=/etc/init.d/iaxmodem start
ExecStop=/etc/init.d/iaxmodem stop
ExecReload=/etc/init.d/iaxmodem reload

######################################################################
# SYSTEMD UNIT: iaxmodem@ttyIAX0.service
######################################################################
# /etc/systemd/system/iaxmodem@.service
[Unit]
Description=IAXmodem for %I
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/iaxmodem %I
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target

######################################################################
# SYSTEMD UNIT: iaxmodem@ttyIAX1.service
######################################################################
# /etc/systemd/system/iaxmodem@.service
[Unit]
Description=IAXmodem for %I
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/iaxmodem %I
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target

######################################################################
# CMD: iptables rules (falls vorhanden)
######################################################################

######################################################################
# CMD: nftables rules (falls vorhanden)
######################################################################

######################################################################
# CMD: ufw status (falls genutzt)
######################################################################
Status: inactive

######################################################################
# CMD: Asterisk version
######################################################################
Asterisk 20.18.2

######################################################################
# CMD: Loaded fax modules
######################################################################
Module                         Description                              Use Count  Status      Support Level
res_fax.so                     Generic FAX Applications                 1          Running              core
res_fax_spandsp.so             Spandsp G.711 and T.38 FAX Technologies  0          Running          extended
2 modules loaded

######################################################################
# CMD: Fax capabilities
######################################################################


Registered FAX Technology Modules:

Type            : Spandsp
Description     : Spandsp FAX Driver
Capabilities    : SEND RECEIVE T.38 G.711 GATEWAY

1 registered modules


######################################################################
# CMD: PJSIP endpoints overview
######################################################################

 Endpoint:  <Endpoint/CID.....................................>  <State.....>  <Channels.>
    I/OAuth:  <AuthId/UserName...........................................................>
        Aor:  <Aor............................................>  <MaxContact>
      Contact:  <Aor/ContactUri..........................> <Hash....> <Status> <RTT(ms)..>
  Transport:  <TransportId........>  <Type>  <cos>  <tos>  <BindAddress..................>
   Identify:  <Identify/Endpoint.........................................................>
        Match:  <criteria.........................>
    Channel:  <ChannelId......................................>  <State.....>  <Time.....>
        Exten: <DialedExten...........>  CLCID: <ConnectedLineCID.......>
==========================================================================================

 Endpoint:  1und1-endpoint                                       Not in use    0 of inf
    OutAuth:  1und1-auth/4923XXXXXXXXX
        Aor:  1und1-aor                                          0
      Contact:  1und1-aor/sip:sip.1und1.de                 db3bd3b67a NonQual         nan
  Transport:  transport-udp             udp      0      0  0.0.0.0:5070
   Identify:  1und1-identify/1und1-endpoint
        Match: 212.227.0.0/16


Objects found: 1


######################################################################
# CMD: PJSIP registrations
######################################################################

 <Registration/ServerURI..............................>  <Auth....................>  <Status.......>
==========================================================================================

 1und1/sip:sip.1und1.de                                  1und1-auth                  Registered        (exp. 1s)

Objects found: 1


# DONE
root@fax:/home/faxuser# 




```



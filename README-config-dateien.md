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


***Vorbereitung des systems, anlage von ordnern und beispieldateien***
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




**Augabe-script für meine dateien**
```bash```
# Sammel-Export: alle typischen Dateien, die man für Asterisk(PJSIP)+Fax(SpanDSP)+HylaFAX+iaxmodem anfasst.
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
show_file /var/spool/hylafax/etc/setup.cache

# iaxmodem Konfiguration (je nach Distribution/Installationsart)
show_file /etc/iaxmodem/iaxmodem.conf
show_file /etc/default/iaxmodem
show_file /etc/init.d/iaxmodem

# systemd Units (wichtig wenn du Dienste angepasst hast)
show_unit asterisk.service
show_unit hylafax.service
show_unit iaxmodem.service
show_unit iaxmodem@ttyIAX0.service
show_unit iaxmodem@ttyIAX1.service

###############################################################################
# Optional: Firewall/NAT (falls du dafür explizit Regeln gesetzt hast)
###############################################################################
# (nur anzeigen, wenn du wirklich etwas angepasst hast)
show_cmd "iptables rules (falls vorhanden)" bash -lc 'iptables-save 2>/dev/null | sed -n "1,2000p"'
show_cmd "nftables rules (falls vorhanden)" bash -lc 'nft list ruleset 2>/dev/null | sed -n "1,2000p"'
show_cmd "ufw status (falls genutzt)" bash -lc 'ufw status verbose 2>/dev/null || true'

###############################################################################
# Optional: Asterisk-Checks (hilft bei Reproduzierbarkeit, enthält aber evtl. Nummern)
###############################################################################
show_cmd "Asterisk version" bash -lc 'asterisk -V 2>/dev/null || true'
show_cmd "Loaded fax modules" bash -lc 'asterisk -rx "module show like fax" 2>/dev/null || true'
show_cmd "Fax capabilities" bash -lc 'asterisk -rx "fax show capabilities" 2>/dev/null || true'
show_cmd "PJSIP endpoints overview" bash -lc 'asterisk -rx "pjsip show endpoints" 2>/dev/null || true'
show_cmd "PJSIP registrations" bash -lc 'asterisk -rx "pjsip show registrations" 2>/dev/null || true'

echo
echo "# DONE"

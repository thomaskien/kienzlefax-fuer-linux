#!/usr/bin/env bash
set -euo pipefail

ENVFILE="/etc/kienzlefax-installer.env"
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
fi

EXT="/etc/asterisk/extensions.conf"
cp -a "$EXT" "${EXT}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

# Install-time values (NO hardcoded personal numbers)
KFX_FAX_DID="${KFX_FAX_DID:-}"
KFX_CALLERID_NUM="${KFX_CALLERID_NUM:-}"
KFX_CALLERID_NAME="${KFX_CALLERID_NAME:-Fax}"
KFX_PJSIP_ENDPOINT="${KFX_PJSIP_ENDPOINT:-kfx-provider-endpoint}"

# Default: CallerID uses the SIP number (same as username)
if [ -z "${KFX_CALLERID_NUM}" ]; then
  KFX_CALLERID_NUM="${KFX_SIP_NUMBER:-}"
fi

ensure_capacity_modules_in_modules_conf(){
  local modules_conf="/etc/asterisk/modules.conf"
  mkdir -p /etc/asterisk
  if [ -f "$modules_conf" ]; then
    cp -a "$modules_conf" "${modules_conf}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
  touch "$modules_conf"

  python3 - "$modules_conf" <<'PY'
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
  command -v asterisk >/dev/null 2>&1 || return 0
  ensure_capacity_modules_in_modules_conf
  asterisk -rx "module load func_groupcount.so" >/dev/null 2>&1 || true
  asterisk -rx "module load func_lock.so" >/dev/null 2>&1 || true

  local group_out lock_out
  group_out="$(asterisk -rx "module show like func_groupcount" 2>/dev/null || true)"
  lock_out="$(asterisk -rx "module show like func_lock" 2>/dev/null || true)"

  if [[ "$group_out" != *"func_groupcount.so"* || "$group_out" != *"Running"* ]]; then
    echo "ERROR: func_groupcount.so ist nicht geladen." >&2
    echo "$group_out" >&2
    exit 1
  fi
  if [[ "$lock_out" != *"func_lock.so"* || "$lock_out" != *"Running"* ]]; then
    echo "ERROR: func_lock.so ist nicht geladen." >&2
    echo "$lock_out" >&2
    exit 1
  fi
}

ensure_capacity_modules_running

# Write dialplan WITHOUT shell expansion (Asterisk vars must survive)
cat >"$EXT" <<'EOF'
[general]
static=yes
writeprotect=no
clearglobalvars=no

; =============================================================================
; kienzlefax — Asterisk Dialplan
; - Fax-Out: Dial() + SendFAX() im callee Gosub
; - Status/Result "Quelle der Wahrheit": kfx_update_status.agi (send_start / dial_end / send_end)
; - Robust: Hangup-Handler auf PJSIP-Kanal als Fallback (weil FAX* Variablen dort gültig sind)
;
; WICHTIG:
; - Der Worker originiert via AMI auf: Local/<exten>@fax-out/n und hält den Originate-Channel per Wait lange genug.
; - DIALSTATUS=CANCEL + HANGUPCAUSE=19 wird im AGI als NOANSWER behandelt (Retry 3x).
; =============================================================================

; =============================================================================
; FAX-OUT
; =============================================================================
[fax-out]

exten => kfx_missing_file,1,NoOp(FAX OUT ERROR: missing KFX_FILE | jobid=${KFX_JOBID})
 same => n,AGI(kfx_update_status.agi,${KFX_JOBID},dial_end,CHANUNAVAIL,0)
 same => n,Hangup()

exten => h,1,NoOp(fax-out h-extension | jobid=${KFX_JOBID} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})
 same => n,AGI(kfx_update_status.agi,${KFX_JOBID},dial_end,${DIALSTATUS},${HANGUPCAUSE})
 same => n,Hangup()

exten => _49X.,1,NoOp(FAX OUT normalize 49... -> national | jobid=${KFX_JOBID} file=${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,Set(NORM=0${EXTEN:2})
 same => n,NoOp(NORMALIZED=${NORM})
 same => n,GotoIf($[ "${KFX_FILE}" = "" ]?kfx_missing_file,1)

 same => n(kfx_capacity_wait),Gosub(kfx_fax_capacity,s,1)
 same => n,GotoIf($["${KFX_CAPACITY_OK}"="1"]?kfx_capacity_ok)
 same => n,NoOp(FAX OUT waiting: global fax capacity full (limit ${KFX_CAPACITY_LIMIT}))
 same => n,Wait(2)
 same => n,Goto(kfx_capacity_wait)
 same => n(kfx_capacity_ok),NoOp(FAX OUT capacity reserved: ${KFX_CAPACITY_COUNT_BEFORE}+1/${KFX_CAPACITY_LIMIT})

 same => n,Set(CHANNEL(accountcode)=${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 same => n,Set(CALLERID(num)=__KFX_CALLERID_NUM__)
 same => n,Set(CALLERID(name)=__KFX_CALLERID_NAME__)

 same => n,Dial(PJSIP/${NORM}@__KFX_PJSIP_ENDPOINT__,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))
 same => n,Hangup()

exten => _0X.,1,NoOp(FAX OUT national | jobid=${KFX_JOBID} file=${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,GotoIf($[ "${KFX_FILE}" = "" ]?kfx_missing_file,1)

 same => n(kfx_capacity_wait),Gosub(kfx_fax_capacity,s,1)
 same => n,GotoIf($["${KFX_CAPACITY_OK}"="1"]?kfx_capacity_ok)
 same => n,NoOp(FAX OUT waiting: global fax capacity full (limit ${KFX_CAPACITY_LIMIT}))
 same => n,Wait(2)
 same => n,Goto(kfx_capacity_wait)
 same => n(kfx_capacity_ok),NoOp(FAX OUT capacity reserved: ${KFX_CAPACITY_COUNT_BEFORE}+1/${KFX_CAPACITY_LIMIT})

 same => n,Set(CHANNEL(accountcode)=${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 same => n,Set(CALLERID(num)=__KFX_CALLERID_NUM__)
 same => n,Set(CALLERID(name)=__KFX_CALLERID_NAME__)

 same => n,Dial(PJSIP/${EXTEN}@__KFX_PJSIP_ENDPOINT__,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))
 same => n,Hangup()

; =============================================================================
; GLOBAL FAX CAPACITY GUARD
; - Counts logical fax connections, not Asterisk channel legs.
; - Outbound: GROUP is set on the Local channel in [fax-out].
; - Inbound: GROUP is set on the inbound PJSIP channel before Answer().
; - Group membership ends automatically when the channel hangs up.
; =============================================================================
[kfx_fax_capacity]
exten => s,1,NoOp(kfx_fax_capacity | chan=${CHANNEL(name)})
 same => n,Set(KFX_CAPACITY_LIMIT=3)
 same => n,Set(KFX_CAPACITY_LOCK=${LOCK(kfx_fax_capacity_lock)})
 same => n,GotoIf($["${KFX_CAPACITY_LOCK}"="1"]?locked:lock_failed)

 same => n(locked),Set(KFX_CAPACITY_COUNT_BEFORE=${GROUP_COUNT(active@kfx_fax_capacity)})
 same => n,GotoIf($[${KFX_CAPACITY_COUNT_BEFORE} >= ${KFX_CAPACITY_LIMIT}]?full)
 same => n,Set(GROUP(kfx_fax_capacity)=active)
 same => n,Set(KFX_CAPACITY_OK=1)
 same => n,Set(KFX_CAPACITY_UNLOCK=${UNLOCK(kfx_fax_capacity_lock)})
 same => n,Return()

 same => n(full),Set(KFX_CAPACITY_OK=0)
 same => n,Set(KFX_CAPACITY_UNLOCK=${UNLOCK(kfx_fax_capacity_lock)})
 same => n,Return()

 same => n(lock_failed),NoOp(kfx_fax_capacity: mutex acquisition failed; fail closed)
 same => n,Set(KFX_CAPACITY_OK=0)
 same => n,Return()

; =============================================================================
; CALLEE GOSUB: SendFAX läuft auf dem PJSIP-Kanal
; =============================================================================
[kfx_sendfax]
exten => s,1,NoOp(kfx_sendfax | jobid=${ARG1} file=${ARG2} chan=${CHANNEL(name)})
 same => n,Set(CHANNEL(accountcode)=${ARG1})
 same => n,Set(CDR(userfield)=kfx:${ARG1})
 same => n,Set(AGISIGHUP=no)
 same => n,Set(AGIEXITONHANGUP=no)
 same => n,Set(CHANNEL(hangup_handler_push)=kfx_sendfax_hangup,s,1(${ARG1}))
 same => n,AGI(kfx_update_status.agi,${ARG1},send_start)
 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,TryExec(SendFAX(${ARG2}))
 same => n,NoOp(FAX done | FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} FAXPAGES=${FAXPAGES} FAXBITRATE=${FAXBITRATE} FAXECM=${FAXECM} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})
 same => n,AGI(kfx_update_status.agi,${ARG1},send_end,${FAXSTATUS},${FAXERROR},${FAXPAGES},${FAXBITRATE},${FAXECM},${DIALSTATUS},${HANGUPCAUSE})
 same => n,Return()

[kfx_sendfax_hangup]
exten => s,1,NoOp(kfx_sendfax_hangup | jobid=${ARG1} chan=${CHANNEL(name)} FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} FAXPAGES=${FAXPAGES} FAXBITRATE=${FAXBITRATE} FAXECM=${FAXECM} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})
 same => n,Set(AGISIGHUP=no)
 same => n,Set(AGIEXITONHANGUP=no)
 same => n,AGI(kfx_update_status.agi,${ARG1},send_end,${FAXSTATUS},${FAXERROR},${FAXPAGES},${FAXBITRATE},${FAXECM},${DIALSTATUS},${HANGUPCAUSE})
 same => n,Return()

; =============================================================================
; FAX-IN
; =============================================================================
[fax-in]
exten => __KFX_FAX_DID__,1,NoOp(Inbound Fax)
 same => n,Gosub(kfx_fax_capacity,s,1)
 same => n,GotoIf($["${KFX_CAPACITY_OK}"="1"]?kfx_capacity_ok)
 same => n,NoOp(Inbound Fax rejected: global fax capacity full (limit ${KFX_CAPACITY_LIMIT}))
 same => n,Hangup(17)
 same => n(kfx_capacity_ok),NoOp(Inbound Fax capacity reserved: ${KFX_CAPACITY_COUNT_BEFORE}+1/${KFX_CAPACITY_LIMIT})
 same => n,Answer()
 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,Set(JITTERBUFFER(adaptive)=default)

 same => n,Set(FAXSTAMP=${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)})
 same => n,Set(FROMRAW=${CALLERID(num)})
 same => n,Set(FROM=${FILTER(0-9,${FROMRAW})})
 same => n,ExecIf($["${FROM}"=""]?Set(FROM=unknown))

 same => n,Set(UID=${CUT(UNIQUEID,.,2)})
 same => n,ExecIf($["${UID}"=""]?Set(UID=${UNIQUEID}))

 same => n,Set(FAXBASE=${FAXSTAMP}_${FROM}_${UID})
 same => n,Set(TIFF=/var/spool/asterisk/fax1/${FAXBASE}.tif)
 same => n,Set(PDF=/srv/scan/fax-eingang/${FAXBASE}.pdf)
 same => n,System(mkdir -p /srv/scan/fax-eingang)
 same => n,System(chmod 0777 /srv/scan/fax-eingang)

 same => n,ReceiveFAX(${TIFF})
 same => n,NoOp(FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} PAGES=${FAXPAGES})

 same => n,Set(HASFILE=${STAT(e,${TIFF})})
 same => n,Set(SIZE=${STAT(s,${TIFF})})
 same => n,GotoIf($[${HASFILE} & ${SIZE} > 0]?to_pdf:no_file)

 same => n(to_pdf),System(tiff2pdf -o ${PDF} ${TIFF})
 same => n,GotoIf($["${SYSTEMSTATUS}"="SUCCESS"]?cleanup:keep_tiff)

 same => n(cleanup),System(chmod 0666 ${PDF})
 same => n,System(rm -f ${TIFF})
 same => n,Hangup()

 same => n(keep_tiff),NoOp(PDF failed or partial - keeping TIFF: ${TIFF})
 same => n,Hangup()

 same => n(no_file),NoOp(No TIFF created. Nothing to convert.)
 same => n,Hangup()
EOF

# Replace placeholders with install-time values
if [ -n "${KFX_FAX_DID}" ]; then
  sed -i "s/__KFX_FAX_DID__/${KFX_FAX_DID}/g" "$EXT"
else
  echo "WARN: KFX_FAX_DID ist leer; fax-in exten bleibt Platzhalter." >&2
fi

if [ -n "${KFX_CALLERID_NUM}" ]; then
  sed -i "s/__KFX_CALLERID_NUM__/${KFX_CALLERID_NUM}/g" "$EXT"
else
  echo "WARN: KFX_CALLERID_NUM ist leer; Platzhalter bleibt." >&2
fi

sed -i "s/__KFX_CALLERID_NAME__/${KFX_CALLERID_NAME}/g" "$EXT"
sed -i "s/__KFX_PJSIP_ENDPOINT__/${KFX_PJSIP_ENDPOINT}/g" "$EXT"

asterisk -rx "dialplan reload" || true

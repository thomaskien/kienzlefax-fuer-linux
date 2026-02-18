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

# Default: CallerID uses the SIP number (same as username)
if [ -z "${KFX_CALLERID_NUM}" ]; then
  KFX_CALLERID_NUM="${KFX_SIP_NUMBER:-}"
fi

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

 same => n,Set(CHANNEL(accountcode)=${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 same => n,Set(CALLERID(num)=__KFX_CALLERID_NUM__)
 same => n,Set(CALLERID(name)=__KFX_CALLERID_NAME__)

 same => n,Dial(PJSIP/${NORM}@1und1-endpoint,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))
 same => n,Hangup()

exten => _0X.,1,NoOp(FAX OUT national | jobid=${KFX_JOBID} file=${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,GotoIf($[ "${KFX_FILE}" = "" ]?kfx_missing_file,1)

 same => n,Set(CHANNEL(accountcode)=${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 same => n,Set(CALLERID(num)=__KFX_CALLERID_NUM__)
 same => n,Set(CALLERID(name)=__KFX_CALLERID_NAME__)

 same => n,Dial(PJSIP/${EXTEN}@1und1-endpoint,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))
 same => n,Hangup()

; =============================================================================
; CALLEE GOSUB: SendFAX läuft auf dem PJSIP-Kanal
; =============================================================================
[kfx_sendfax]
exten => s,1,NoOp(kfx_sendfax | jobid=${ARG1} file=${ARG2} chan=${CHANNEL(name)})
 same => n,Set(CHANNEL(accountcode)=${ARG1})
 same => n,Set(CDR(userfield)=kfx:${ARG1})
 same => n,Set(CHANNEL(hangup_handler_push)=kfx_sendfax_hangup,s,1(${ARG1}))
 same => n,AGI(kfx_update_status.agi,${ARG1},send_start)
 same => n,TryExec(SendFAX(${ARG2}))
 same => n,NoOp(FAX done | FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} FAXPAGES=${FAXPAGES} FAXBITRATE=${FAXBITRATE} FAXECM=${FAXECM} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})
 same => n,AGI(kfx_update_status.agi,${ARG1},send_end,${FAXSTATUS},${FAXERROR},${FAXPAGES},${FAXBITRATE},${FAXECM},${DIALSTATUS},${HANGUPCAUSE})
 same => n,Return()

[kfx_sendfax_hangup]
exten => s,1,NoOp(kfx_sendfax_hangup | jobid=${ARG1} chan=${CHANNEL(name)} FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} FAXPAGES=${FAXPAGES} FAXBITRATE=${FAXBITRATE} FAXECM=${FAXECM} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})
 same => n,AGI(kfx_update_status.agi,${ARG1},send_end,${FAXSTATUS},${FAXERROR},${FAXPAGES},${FAXBITRATE},${FAXECM},${DIALSTATUS},${HANGUPCAUSE})
 same => n,Return()

; =============================================================================
; FAX-IN
; =============================================================================
[fax-in]
exten => __KFX_FAX_DID__,1,NoOp(Inbound Fax)
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
 same => n,Set(PDF=/var/spool/asterisk/fax/${FAXBASE}.pdf)

 same => n,ReceiveFAX(${TIFF})
 same => n,NoOp(FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} PAGES=${FAXPAGES})

 same => n,Set(HASFILE=${STAT(e,${TIFF})})
 same => n,Set(SIZE=${STAT(s,${TIFF})})
 same => n,GotoIf($[${HASFILE} & ${SIZE} > 0]?to_pdf:no_file)

 same => n(to_pdf),System(tiff2pdf -o ${PDF} ${TIFF})
 same => n,GotoIf($["${SYSTEMSTATUS}"="SUCCESS"]?cleanup:keep_tiff)

 same => n(cleanup),System(rm -f ${TIFF})
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

asterisk -rx "dialplan reload" || true

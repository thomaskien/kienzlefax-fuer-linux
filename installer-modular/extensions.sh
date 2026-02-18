#!/usr/bin/env bash
set -euo pipefail
ENVFILE="/etc/kienzlefax-installer.env"
[ -f "$ENVFILE" ] && source "$ENVFILE"

EXT="/etc/asterisk/extensions.conf"
cp -a "$EXT" "${EXT}.old.kienzlefax.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

cat >"$EXT" <<EOF
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

; --- falls Datei fehlt ---
exten => kfx_missing_file,1,NoOp(FAX OUT ERROR: missing KFX_FILE | jobid=${KFX_JOBID})
 same => n,AGI(kfx_update_status.agi,${KFX_JOBID},dial_end,CHANUNAVAIL,0)
 same => n,Hangup()

; --- h-extension: wird bei Hangup des Local-Channels ausgeführt ---
; Nicht mit Return() enden (kein Gosub-Stack!). Einfach Hangup.
exten => h,1,NoOp(fax-out h-extension | jobid=${KFX_JOBID} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})
 ; Dial-End immer melden (aber: wenn ANSWER, finalisiert AGI NICHT, sondern wartet auf send_end/hangup)
 same => n,AGI(kfx_update_status.agi,${KFX_JOBID},dial_end,${DIALSTATUS},${HANGUPCAUSE})
 same => n,Hangup()

; --- 49... -> 0... ---
exten => _49X.,1,NoOp(FAX OUT normalize 49... -> national | jobid=${KFX_JOBID} file=${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,Set(NORM=0${EXTEN:2})
 same => n,NoOp(NORMALIZED=${NORM})
 same => n,GotoIf($[ "${KFX_FILE}" = "" ]?kfx_missing_file,1)

 ; Job-Tagging (wichtig für Cancel/Orphan-Reconcile)
 same => n,Set(CHANNEL(accountcode)=${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 ; Fax-Optionen
 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 ; CallerID
 same => n,Set(CALLERID(num)=4923319265248)
 same => n,Set(CALLERID(name)=Fax)

 ; Dial: callee Gosub führt SendFAX auf PJSIP-Kanal aus
 ; g = weiter im Dialplan nach Auflegen
 ; U() = Gosub auf callee channel (PJSIP), dort sind FAX* gültig
 same => n,Dial(PJSIP/${NORM}@1und1-endpoint,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))
 same => n,Hangup()

; --- national 0... ---
exten => _0X.,1,NoOp(FAX OUT national | jobid=${KFX_JOBID} file=${KFX_FILE})
 same => n,Set(JITTERBUFFER(adaptive)=default)
 same => n,GotoIf($[ "${KFX_FILE}" = "" ]?kfx_missing_file,1)

 same => n,Set(CHANNEL(accountcode)=${KFX_JOBID})
 same => n,Set(CDR(userfield)=kfx:${KFX_JOBID})

 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)

 same => n,Set(CALLERID(num)=4923319265248)
 same => n,Set(CALLERID(name)=Fax)

 same => n,Dial(PJSIP/${EXTEN}@1und1-endpoint,60,gU(kfx_sendfax^${KFX_JOBID}^${KFX_FILE}))
 same => n,Hangup()


; =============================================================================
; CALLEE GOSUB: SendFAX läuft auf dem PJSIP-Kanal
; =============================================================================
[kfx_sendfax]
exten => s,1,NoOp(kfx_sendfax | jobid=${ARG1} file=${ARG2} chan=${CHANNEL(name)})

 ; Job-Tagging auch auf PJSIP-Kanal
 same => n,Set(CHANNEL(accountcode)=${ARG1})
 same => n,Set(CDR(userfield)=kfx:${ARG1})

 ; Fallback: Hangup-Handler auf PJSIP-Kanal (FAX* Variablen hier noch vorhanden)
 same => n,Set(CHANNEL(hangup_handler_push)=kfx_sendfax_hangup,s,1(${ARG1}))

 ; send_start: status=sending + channel/uniqueid ins job.json
 same => n,AGI(kfx_update_status.agi,${ARG1},send_start)

 ; Der eigentliche Faxversand
 same => n,TryExec(SendFAX(${ARG2}))

 ; Wichtig: nach SendFAX sind FAX* Variablen hier gültig (PJSIP-Kanal)
 same => n,NoOp(FAX done | FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} FAXPAGES=${FAXPAGES} FAXBITRATE=${FAXBITRATE} FAXECM=${FAXECM} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})

 ; send_end: Quelle der Wahrheit (entscheidet OK/RETRY/FAILED nach Policy)
 same => n,AGI(kfx_update_status.agi,${ARG1},send_end,${FAXSTATUS},${FAXERROR},${FAXPAGES},${FAXBITRATE},${FAXECM},${DIALSTATUS},${HANGUPCAUSE})

 same => n,Return()


; =============================================================================
; Hangup Handler auf PJSIP-Kanal (Fallback, falls send_end nicht lief)
; =============================================================================
[kfx_sendfax_hangup]
exten => s,1,NoOp(kfx_sendfax_hangup | jobid=${ARG1} chan=${CHANNEL(name)} FAXSTATUS=${FAXSTATUS} FAXERROR=${FAXERROR} FAXPAGES=${FAXPAGES} FAXBITRATE=${FAXBITRATE} FAXECM=${FAXECM} DIALSTATUS=${DIALSTATUS} HANGUPCAUSE=${HANGUPCAUSE})
 ; Nur sinnvoll, wenn nicht schon SUCCESS/OK in job.json steht – diese Logik macht das AGI konservativ.
 same => n,AGI(kfx_update_status.agi,${ARG1},send_end,${FAXSTATUS},${FAXERROR},${FAXPAGES},${FAXBITRATE},${FAXECM},${DIALSTATUS},${HANGUPCAUSE})
 same => n,Return()


; =============================================================================
; FAX-IN (unverändert aus deinem Stand, nur "UID" (Teil nach Punkt) bleibt wie du es willst)
; =============================================================================
[fax-in]
exten => 4923319265248,1,NoOp(Inbound Fax)
 same => n,Answer()
 same => n,Set(FAXOPT(ecm)=yes)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,Set(JITTERBUFFER(adaptive)=default)

 same => n,Set(FAXSTAMP=${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)})
 same => n,Set(FROMRAW=${CALLERID(num)})
 same => n,Set(FROM=${FILTER(0-9,${FROMRAW})})
 same => n,ExecIf($["${FROM}"=""]?Set(FROM=unknown))

 ; UNIQUEID nur Zähler-Teil nach Punkt
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

asterisk -rx "dialplan reload" || true

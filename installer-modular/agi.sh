#!/usr/bin/env bash
set -euo pipefail

ENVFILE="/etc/kienzlefax-installer.env"
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
fi

backup_file_ts() {
  local f="$1"
  local stamp=".old.kienzlefax.$(date +%Y%m%d-%H%M%S)"
  if [ -e "$f" ]; then
    cp -a "$f" "${f}${stamp}" 2>/dev/null || true
    echo "[INFO] backup: $f -> ${f}${stamp}"
  fi
}

AGI="/var/lib/asterisk/agi-bin/kfx_update_status.agi"
mkdir -p "$(dirname "$AGI")"
backup_file_ts "$AGI" || true

cat >"$AGI" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kfx_update_status.agi — kienzlefax
Version: 1.3.6
Stand:  2026-02-17
Autor:  Dr. Thomas Kienzle

Changelog (komplett):
- 1.3.3:
  - Retry-Policy:
    - BUSY:       15 Versuche, 90s Abstand
    - NOANSWER:    3 Versuche, 120s Abstand (kann angepasst werden)
    - alles andere retryable: 30 Versuche
      - CONGESTION/CHANUNAVAIL: 20s Abstand
      - FAXFAIL (ANSWER aber FAXSTATUS != SUCCESS): 60s Abstand
  - OK nur wenn FAXSTATUS == SUCCESS.
- 1.3.6:
  - Unterstützt Event-Style Aufrufe aus dem Dialplan:
      * ... jobid,send_start
      * ... jobid,dial_end,<DIALSTATUS>,<HANGUPCAUSE>
      * ... jobid,send_end,<FAXSTATUS>,<FAXERROR>,<FAXPAGES>,<FAXBITRATE>,<FAXECM>,<DIALSTATUS>,<HANGUPCAUSE>
    (Legacy-Signatur weiterhin kompatibel.)
  - FIX2: DIALSTATUS=CANCEL + HANGUPCAUSE=19 wird als NOANSWER behandelt (Policy: 3 Versuche),
    weil das in Praxis häufig „keiner geht ran“ bedeutet.
  - Konservative Entscheidung:
    - dial_end mit ANSWER finalisiert NICHT (wartet auf send_end oder Hangup-Handler).
    - send_end ist „Quelle der Wahrheit“ für Fax-Ergebnis.
  - Neue Reason-Klasse NOFAX:
    - Wenn ANSWER aber Fax scheitert/keine Seiten -> nur 3 Versuche (statt 30).
  - Atomare JSON-Schreibweise (tmp + replace), um kaputte job.json zu vermeiden.
"""

import json
import os
import re
import sys
from pathlib import Path
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, Optional, Tuple

BASE = Path("/srv/kienzlefax")
PROC = BASE / "processing"
QUEUE = BASE / "queue"

# Policy nach deinem Stand:
# - BUSY: 15 @ 90s
# - NOANSWER: 3 @ 90s
# - alles andere (nicht BUSY/NOANSWER): 30 @ 20s
# - NOFAX: 3 @ 20s
RETRY_RULES = {
    "BUSY":        {"delay": 90, "max": 15},
    "NOANSWER":    {"delay": 90, "max": 3},
    "CONGESTION":  {"delay": 20, "max": 30},
    "CHANUNAVAIL": {"delay": 20, "max": 30},
    "FAXFAIL":     {"delay": 20, "max": 30},
    "NOFAX":       {"delay": 20, "max": 3},
}

def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def eprint(*a: object) -> None:
    print(*a, file=sys.stderr, flush=True)

def agi_read_env() -> Dict[str, str]:
    env: Dict[str, str] = {}
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            break
        if ":" in line:
            k, v = line.split(":", 1)
            env[k.strip()] = v.strip()
    return env

def agi_send(line: str) -> None:
    sys.stdout.write(line.rstrip("\n") + "\n")
    sys.stdout.flush()

def sanitize_jobid(s: str) -> str:
    s = (s or "").strip()
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s)
    return s

def to_str(x: Any) -> str:
    return "" if x is None else str(x)

def upper(x: Any) -> str:
    return to_str(x).strip().upper()

def parse_pages(s: str) -> Tuple[Optional[int], Optional[int]]:
    s = (s or "").strip()
    if not s:
        return None, None
    m = re.match(r"^\s*(\d+)\s*[/:\s]\s*(\d+)\s*$", s)
    if m:
        return int(m.group(1)), int(m.group(2))
    if s.isdigit():
        return int(s), None
    return None, None

def find_job_json(jobid: str) -> Optional[Path]:
    direct = [
        PROC / jobid / "job.json",
        QUEUE / jobid / "job.json",
    ]
    for p in direct:
        if p.exists():
            return p
    for root in (PROC, QUEUE):
        if not root.exists():
            continue
        for d in root.iterdir():
            jp = d / "job.json"
            if not jp.exists():
                continue
            try:
                with jp.open("r", encoding="utf-8") as f:
                    j = json.load(f)
                if to_str(j.get("job_id") or d.name) == jobid:
                    return jp
            except Exception:
                continue
    return None

def read_json(p: Path) -> Dict[str, Any]:
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)

def write_json_atomic(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)

def set_attempt_meta(job: Dict[str, Any], *, ended: bool, reason: Optional[str]=None, mx: Optional[int]=None) -> None:
    a = job.setdefault("attempt", {})
    if ended:
        a["ended_at"] = now_iso()
    if reason:
        a["last_reason"] = reason
    if mx is not None:
        a["max"] = int(mx)

def apply_retry(job: Dict[str, Any], key: str) -> None:
    rule = RETRY_RULES[key]
    delay = int(rule["delay"])
    mx = int(rule["max"])

    r = job.setdefault("retry", {})
    r["max"] = mx
    r["last_reason"] = key
    r["suggested_delay_sec"] = delay
    r["next_try_at"] = (datetime.now(timezone.utc) + timedelta(seconds=delay)).replace(microsecond=0).isoformat()

    set_attempt_meta(job, ended=True, reason=key, mx=mx)

def set_result_fields(job: Dict[str, Any], **kv: str) -> None:
    res = job.setdefault("result", {})
    for k, v in kv.items():
        if v is None:
            continue
        res[k] = v if isinstance(v, str) else to_str(v)

def normalize_cancel19(dialstatus: str, hangupcause: str) -> str:
    if dialstatus == "CANCEL" and hangupcause == "19":
        return "NOANSWER"
    return dialstatus

def decide_from_send_end(dialstatus: str, hangupcause: str, faxstatus: str, faxerror: str, pages_sent: Optional[int]):
    if faxstatus == "SUCCESS":
        return "OK", "OK"

    nofax = False
    if dialstatus == "ANSWER":
        if pages_sent is not None and pages_sent <= 0:
            nofax = True
        if "dropped prematurely" in (faxerror or "").lower():
            nofax = True
        if faxerror.strip().upper() in ("HANGUP", "NO CARRIER", "NOCARRIER"):
            nofax = True

    if nofax:
        return "RETRY", "NOFAX"

    if dialstatus == "ANSWER":
        return "RETRY", "FAXFAIL"

    if dialstatus in ("BUSY", "NOANSWER", "CONGESTION", "CHANUNAVAIL"):
        return "RETRY", dialstatus

    return "FAILED", faxstatus or dialstatus or "unknown"

def decide_from_dial_end(dialstatus: str):
    if dialstatus == "ANSWER":
        return None, None
    if dialstatus in ("BUSY", "NOANSWER", "CONGESTION", "CHANUNAVAIL"):
        return "RETRY", dialstatus
    if dialstatus == "CANCEL":
        return "FAILED", "CANCEL"
    return "FAILED", dialstatus or "unknown"

def main() -> int:
    agi_env = agi_read_env()

    args = sys.argv[1:]
    if len(args) < 2:
        eprint("kfx_update_status.agi: missing args")
        return 0

    jobid = sanitize_jobid(args[0])
    if not jobid:
        eprint("kfx_update_status.agi: missing jobid")
        return 0

    jp = find_job_json(jobid)
    if not jp:
        eprint(f"kfx_update_status.agi: job.json not found for jobid={jobid}")
        return 0

    try:
        job = read_json(jp)
    except Exception as e:
        eprint(f"kfx_update_status.agi: cannot read {jp}: {e}")
        return 0

    was_cancelled = bool((job.get("cancel") or {}).get("requested"))
    action = upper(args[1])

    if action == "SEND_START":
        job["status"] = "SENDING"
        job["updated_at"] = now_iso()
        a = job.setdefault("attempt", {})
        a.setdefault("started_at", job["updated_at"])
        job.setdefault("asterisk", {})
        chan = agi_env.get("agi_channel", "")
        if chan:
            job["asterisk"]["channel_sendfax"] = chan
        uid = agi_env.get("agi_uniqueid", "")
        if uid:
            job["asterisk"]["uniqueid"] = uid
        try:
            write_json_atomic(jp, job)
        except Exception as e:
            eprint(f"kfx_update_status.agi: write failed {jp}: {e}")
        return 0

    if action == "DIAL_END":
        dialstatus = upper(args[2]) if len(args) >= 3 else ""
        hangupcause = to_str(args[3]).strip() if len(args) >= 4 else ""
        dialstatus = normalize_cancel19(dialstatus, hangupcause)
        set_result_fields(job, dialstatus=dialstatus, hangupcause=hangupcause)

        if was_cancelled:
            job["status"] = "FAILED"
            job.setdefault("result", {})["reason"] = "cancelled"
            set_attempt_meta(job, ended=True, reason="cancelled", mx=(job.get("retry") or {}).get("max"))
            job["end_time"] = now_iso()
            job["updated_at"] = job["end_time"]
            job["finalized_at"] = job.get("finalized_at") or job["end_time"]
            try:
                write_json_atomic(jp, job)
            except Exception as e:
                eprint(f"kfx_update_status.agi: write failed {jp}: {e}")
            return 0

        final_status, reason_key = decide_from_dial_end(dialstatus)
        if final_status is None:
            job["updated_at"] = now_iso()
            try:
                write_json_atomic(jp, job)
            except Exception as e:
                eprint(f"kfx_update_status.agi: write failed {jp}: {e}")
            return 0

        if final_status == "RETRY" and reason_key in RETRY_RULES:
            job["status"] = "RETRY"
            job.setdefault("result", {})["reason"] = reason_key
            apply_retry(job, reason_key)
        else:
            job["status"] = "FAILED"
            job.setdefault("result", {})["reason"] = reason_key or "FAILED"
            set_attempt_meta(job, ended=True, reason=reason_key or "FAILED", mx=(job.get("retry") or {}).get("max"))
            job["finalized_at"] = job.get("finalized_at") or now_iso()

        job["end_time"] = now_iso()
        job["updated_at"] = job["end_time"]

        try:
            write_json_atomic(jp, job)
        except Exception as e:
            eprint(f"kfx_update_status.agi: write failed {jp}: {e}")

        try:
            agi_send(f'SET VARIABLE KFX_JOB_STATUS "{job.get("status","")}"')
        except Exception:
            pass
        return 0

    if action == "SEND_END":
        faxstatus = upper(args[2]) if len(args) >= 3 else ""
        faxerror = to_str(args[3]).strip() if len(args) >= 4 else ""
        faxpages_raw = to_str(args[4]).strip() if len(args) >= 5 else ""
        faxbitrate = to_str(args[5]).strip() if len(args) >= 6 else ""
        faxecm = to_str(args[6]).strip() if len(args) >= 7 else ""
        dialstatus = upper(args[7]) if len(args) >= 8 else ""
        hangupcause = to_str(args[8]).strip() if len(args) >= 9 else ""

        dialstatus = normalize_cancel19(dialstatus, hangupcause)

        sent, total = parse_pages(faxpages_raw)
        set_result_fields(
            job,
            faxstatus=faxstatus,
            faxerror=faxerror,
            faxpages_raw=faxpages_raw,
            faxbitrate=faxbitrate,
            faxecm=faxecm,
            dialstatus=dialstatus,
            hangupcause=hangupcause,
        )
        res = job.setdefault("result", {})
        if sent is not None:
            res["faxpages_sent"] = sent
        if total is not None:
            res["faxpages_total"] = total

        if was_cancelled or dialstatus == "CANCEL":
            job["status"] = "FAILED"
            res["reason"] = "cancelled" if was_cancelled else "CANCEL"
            set_attempt_meta(job, ended=True, reason=res["reason"], mx=(job.get("retry") or {}).get("max"))
            job["finalized_at"] = job.get("finalized_at") or now_iso()
        else:
            final_status, reason_key = decide_from_send_end(dialstatus, hangupcause, faxstatus, faxerror, sent)
            if final_status == "OK":
                job["status"] = "OK"
                res["reason"] = "OK"
                set_attempt_meta(job, ended=True, reason="OK", mx=(job.get("retry") or {}).get("max"))
                job["finalized_at"] = job.get("finalized_at") or now_iso()
            elif final_status == "RETRY" and reason_key in RETRY_RULES:
                job["status"] = "RETRY"
                res["reason"] = reason_key
                apply_retry(job, reason_key)
            else:
                job["status"] = "FAILED"
                res["reason"] = reason_key or "FAILED"
                set_attempt_meta(job, ended=True, reason=res["reason"], mx=(job.get("retry") or {}).get("max"))
                job["finalized_at"] = job.get("finalized_at") or now_iso()

        job["end_time"] = now_iso()
        job["updated_at"] = job["end_time"]

        try:
            write_json_atomic(jp, job)
        except Exception as e:
            eprint(f"kfx_update_status.agi: write failed {jp}: {e}")

        try:
            agi_send(f'SET VARIABLE KFX_JOB_STATUS "{job.get("status","")}"')
        except Exception:
            pass
        return 0

    # Legacy fallback:
    legacy = args[1:]
    while len(legacy) < 8:
        legacy.append("")
    dialstatus = upper(legacy[0])
    hangupcause = to_str(legacy[1]).strip()
    faxstatus = upper(legacy[2])
    faxerror = to_str(legacy[3]).strip()
    faxpages_raw = to_str(legacy[4]).strip()
    faxbitrate = to_str(legacy[5]).strip()
    faxecm = to_str(legacy[6]).strip()

    dialstatus = normalize_cancel19(dialstatus, hangupcause)
    sent, total = parse_pages(faxpages_raw)

    set_result_fields(
        job,
        dialstatus=dialstatus,
        hangupcause=hangupcause,
        faxstatus=faxstatus,
        faxerror=faxerror,
        faxpages_raw=faxpages_raw,
        faxbitrate=faxbitrate,
        faxecm=faxecm,
    )
    res = job.setdefault("result", {})
    if sent is not None:
        res["faxpages_sent"] = sent
    if total is not None:
        res["faxpages_total"] = total

    if was_cancelled:
        job["status"] = "FAILED"
        res["reason"] = "cancelled"
        set_attempt_meta(job, ended=True, reason="cancelled", mx=(job.get("retry") or {}).get("max"))
        job["finalized_at"] = job.get("finalized_at") or now_iso()
    else:
        if faxstatus == "SUCCESS":
            job["status"] = "OK"
            res["reason"] = "OK"
            set_attempt_meta(job, ended=True, reason="OK", mx=(job.get("retry") or {}).get("max"))
            job["finalized_at"] = job.get("finalized_at") or now_iso()
        else:
            final_status, reason_key = decide_from_send_end(dialstatus, hangupcause, faxstatus, faxerror, sent)
            if final_status == "RETRY" and reason_key in RETRY_RULES:
                job["status"] = "RETRY"
                res["reason"] = reason_key
                apply_retry(job, reason_key)
            else:
                job["status"] = "FAILED"
                res["reason"] = reason_key or "FAILED"
                set_attempt_meta(job, ended=True, reason=res["reason"], mx=(job.get("retry") or {}).get("max"))
                job["finalized_at"] = job.get("finalized_at") or now_iso()

    job["end_time"] = now_iso()
    job["updated_at"] = job["end_time"]
    try:
        write_json_atomic(jp, job)
    except Exception as e:
        eprint(f"kfx_update_status.agi: write failed {jp}: {e}")

    try:
        agi_send(f'SET VARIABLE KFX_JOB_STATUS "{job.get("status","")}"')
    except Exception:
        pass
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        eprint(f"kfx_update_status.agi: fatal: {e}")
        sys.exit(0)
PY

chmod 0755 "$AGI"

if id asterisk >/dev/null 2>&1; then
  chown asterisk:asterisk "$AGI" 2>/dev/null || true
else
  chown root:root "$AGI" 2>/dev/null || true
fi

python3 -m py_compile "$AGI" >/dev/null 2>&1 || {
  echo "ERROR: Python compile failed for $AGI" >&2
  exit 1
}

echo "[OK] AGI installed: $AGI"

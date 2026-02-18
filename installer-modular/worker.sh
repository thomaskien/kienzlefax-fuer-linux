sudo tee /usr/local/bin/kienzlefax-worker.py >/dev/null <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kienzlefax-worker.py — Asterisk-Only Worker (SendFAX)
Version: 1.3.6
Stand:  2026-02-18
Autor:  Dr. Thomas Kienzle

Changelog (komplett):
- 1.2.4:
  - Live-Status-Felder (faxstat -sal) in job.json (HylaFAX).
  - Reboot-sicherer Lock via flock.
- 1.3.0:
  - Beginn Umstieg von HylaFAX-sendfax auf Asterisk AMI Originate + Dialplan SendFAX().
- 1.3.1:
  - AMI-basierter Versand stabilisiert; Rechte/Manager-User Themen sichtbar gemacht.
- 1.3.2:
  - HylaFAX-Legacy entfernt: Finalisierung basiert ausschließlich auf AGI-Ergebnis in job.json.
  - Retry-Handling: status=RETRY => zurück in Queue (Backoff via retry.next_try_at, attempt, etc.).
  - Cooldown nach jedem Call-Ende (terminal oder RETRY) für Gerätepause.
  - Asterisk-Originate so implementiert, dass fax-out NICHT doppelt ausgeführt wird:
    Local/<exten>@<context>/n + Application=Wait (kein Context/Exten/Priority im AMI-Action).
  - PDF->TIFF/F Konvertierung (tiffg4) für SendFAX.
  - Report+Dokument werden weiterhin als PDF zusammengeführt (qpdf), für Archiv/Fehler.
- 1.3.3:
  - Retry-Limits werden erzwungen (basierend auf retry.* Feldern).
  - Report enthält Retry-Infos.
- 1.3.4:
  - Versuchszähler umgebaut (attempt.current als kanonisch).
- 1.3.5:
  - FIX: attempt.current wird jetzt beim START eines Attempts hochgezählt (submit_job),
    nicht beim Requeue. Dadurch zählt jeder tatsächliche Originate/Call genau 1 Versuch,
    unabhängig davon, ob/wo der Job requeued wird.
  - Limit-Prüfung: wenn attempt.current > attempt.max (oder retry.max) -> final FAILED.
  - POST_CALL_COOLDOWN default 20s (per ENV übersteuerbar).
- 1.3.6:
  - Konservativ/Robustheit:
    - AMI Originate Wait-Sekunden parametrisierbar (Default 3600; schützt vor "Wait(1)" Regression).
    - Cancel-Handling: "aktiv" umfasst jetzt auch SUBMITTED/PROCESSING (Status-Timing ist nicht immer deterministisch).
    - Retry-Log zeigt next_attempt zur besseren Nachvollziehbarkeit (keine Verhaltensänderung).
"""

import fcntl
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Tuple, List

BASE = Path(os.environ.get("KFX_BASE", "/srv/kienzlefax"))
QUEUE = BASE / "queue"
PROC = BASE / "processing"
ARCH_OK = BASE / "sendeberichte"
FAIL_IN = BASE / "sendefehler" / "eingang"
FAIL_OUT = BASE / "sendefehler" / "berichte"

AMI_HOST = os.environ.get("KFX_AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("KFX_AMI_PORT", "5038"))
AMI_USER = os.environ.get("KFX_AMI_USER", "kfx")
AMI_PASS = os.environ.get("KFX_AMI_PASS", "")
DIAL_CONTEXT = os.environ.get("KFX_DIAL_CONTEXT", "fax-out")

QPDF_BIN = os.environ.get("KFX_QPDF_BIN", "qpdf")
GS_BIN = os.environ.get("KFX_GS_BIN", "gs")
PDF_HEADER_SCRIPT = Path(os.environ.get("KFX_PDF_HEADER_SCRIPT", "/usr/local/bin/pdf_with_header.sh"))

MAX_INFLIGHT_PROCESSING = int(os.environ.get("KFX_MAX_INFLIGHT", "1"))
POLL_INTERVAL_SEC = float(os.environ.get("KFX_POLL_INTERVAL_SEC", "1.0"))
POST_CALL_COOLDOWN_SEC = float(os.environ.get("KFX_POST_CALL_COOLDOWN_SEC", "20.0"))

# wichtig: Default 3600 wie im funktionierenden System
AMI_ORIGINATE_WAIT_SEC = int(os.environ.get("KFX_AMI_ORIGINATE_WAIT_SEC", "3600"))

TIFF_DPI = os.environ.get("KFX_TIFF_DPI", "204x196")
TIFF_DEVICE = os.environ.get("KFX_TIFF_DEVICE", "tiffg4")

LOCKFILE = BASE / ".kienzlefax-worker.lock"
LOG_PREFIX = "kienzlefax-worker"
_lock_fd: Optional[int] = None
_next_submit_ts: float = 0.0

def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def log(msg: str) -> None:
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"[{ts}] {LOG_PREFIX}: {msg}", flush=True)

def safe_mkdir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)

def read_json(p: Path) -> Dict[str, Any]:
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)

def write_json(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, p)

def sanitize_basename(name: str) -> str:
    name = (name or "").strip()
    name = re.sub(r"\s+", "_", name)
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
    name = name.strip("._-")
    return name or "fax"

def normalize_number(num: str) -> str:
    num = (num or "").strip()
    num = re.sub(r"\D+", "", num)
    return num

def list_jobdirs(root: Path) -> List[Path]:
    if not root.exists():
        return []
    dirs = [p for p in root.iterdir() if p.is_dir()]
    dirs.sort(key=lambda x: x.name)
    return dirs

def run_cmd(cmd: List[str], *, env: Optional[dict]=None, timeout: Optional[int]=None) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or ""), (p.stderr or "")

def add_header_pdf(pdf: Path) -> Path:
    if not PDF_HEADER_SCRIPT.exists():
        return pdf
    out = pdf.with_name(pdf.stem + "_hdr.pdf")
    try:
        subprocess.run([str(PDF_HEADER_SCRIPT), str(pdf), str(out)],
                       check=True, capture_output=True, text=True, timeout=60)
        if out.exists() and out.stat().st_size > 0:
            return out
    except Exception as e:
        log(f"header script failed -> continue without header: {e}")
    return pdf

def pdf_to_tiff_g4(pdf: Path, tif: Path) -> None:
    cmd = [
        GS_BIN,
        "-q","-dNOPAUSE","-dBATCH","-dSAFER",
        f"-sDEVICE={TIFF_DEVICE}",
        f"-r{TIFF_DPI}",
        "-sPAPERSIZE=a4","-dFIXEDMEDIA","-dPDFFitPage",
        f"-sOutputFile={str(tif)}",
        str(pdf),
    ]
    rc, so, se = run_cmd(cmd)
    if rc != 0 or (not tif.exists()) or tif.stat().st_size == 0:
        raise RuntimeError(f"ghostscript pdf->tiff failed rc={rc} out={so.strip()} err={se.strip()}")

def merge_report_and_doc(report_pdf: Path, doc_pdf: Path, out_pdf: Path) -> None:
    cmd = [QPDF_BIN, "--empty", "--pages", str(report_pdf), str(doc_pdf), "--", str(out_pdf)]
    rc, so, se = run_cmd(cmd)
    if rc != 0:
        raise RuntimeError(f"qpdf merge failed rc={rc} out={so.strip()} err={se.strip()}")

def ensure_dirs() -> None:
    for p in (QUEUE, PROC, ARCH_OK, FAIL_IN, FAIL_OUT):
        safe_mkdir(p)

def acquire_lock() -> None:
    global _lock_fd
    safe_mkdir(BASE)
    fd = os.open(str(LOCKFILE), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise SystemExit(f"{LOG_PREFIX}: already running (lock held: {LOCKFILE})")
    try:
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode("ascii", errors="ignore"))
        os.fsync(fd)
    except Exception:
        pass
    _lock_fd = fd

def release_lock() -> None:
    global _lock_fd
    if _lock_fd is None:
        return
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        os.close(_lock_fd)
    except Exception:
        pass
    _lock_fd = None

def retry_due(job: Dict[str, Any]) -> bool:
    rt = (job.get("retry") or {}).get("next_try_at")
    if not rt:
        return True
    try:
        dt = datetime.fromisoformat(str(rt).replace("Z", "+00:00")).astimezone(timezone.utc)
        return datetime.now(timezone.utc) >= dt
    except Exception:
        return True

def _st_norm(job: Dict[str, Any]) -> str:
    return str(job.get("status") or "").strip().upper()

def count_inflight() -> int:
    n = 0
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        st = _st_norm(job)
        if st in ("CLAIMED", "SUBMITTED", "PROCESSING", "CALLING", "SENDING"):
            n += 1
    return n

def get_busy_numbers() -> set[str]:
    busy: set[str] = set()
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        st = _st_norm(job)
        if st in ("CLAIMED", "SUBMITTED", "PROCESSING", "CALLING", "SENDING", "RETRY_WAIT"):
            num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
            if num:
                busy.add(num)
    return busy

def claim_next_job_skipping_busy(busy_numbers: set[str]) -> Optional[Path]:
    for j in list_jobdirs(QUEUE):
        jp = j / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        if not retry_due(job):
            continue
        num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
        if num and num in busy_numbers:
            continue
        target = PROC / j.name
        try:
            j.rename(target)
            log(f"claimed {j.name} (num={num or 'n/a'})")
            return target
        except Exception as e:
            log(f"claim rename failed for {j.name}: {e}")
            continue
    return None

def find_original_pdf_in_jobdir(jobdir: Path) -> Optional[Path]:
    for c in (jobdir / "doc.pdf", jobdir / "source.pdf"):
        try:
            if c.exists() and c.stat().st_size > 0:
                return c
        except Exception:
            pass
    return None

def copy_original_to_fail_in(jobdir: Path, job: Dict[str, Any]) -> None:
    safe_mkdir(FAIL_IN)
    src = job.get("source") or {}
    jobid = job.get("job_id") or jobdir.name
    orig_path = find_original_pdf_in_jobdir(jobdir)
    if not orig_path:
        return
    base = sanitize_basename(Path(src.get("filename_original") or "document").stem) or "document"
    dest = FAIL_IN / f"{base}.pdf"
    if dest.exists():
        dest = FAIL_IN / f"{base}__{jobid}.pdf"
    shutil.copy2(str(orig_path), str(dest))
    log(f"fail: original copied -> {dest.name}")

def build_report_pdf(job: Dict[str, Any], out_pdf: Path) -> None:
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas
    c = canvas.Canvas(str(out_pdf), pagesize=A4)
    _, h = A4

    status = str(job.get("status") or "").upper()
    res = job.get("result") or {}
    reason = str(res.get("reason") or "")
    dial = str(res.get("dialstatus") or "")
    hcause = str(res.get("hangupcause") or "")
    faxst = str(res.get("faxstatus") or "")
    faxerr = str(res.get("faxerror") or "")
    pages_raw = str(res.get("faxpages_raw") or "")

    retry = job.get("retry") or {}
    r_max = retry.get("max")
    r_next = retry.get("next_try_at")
    r_last = retry.get("last_reason")

    a = job.get("attempt") or {}
    a_cur = a.get("current")
    a_max = a.get("max")
    a_last = a.get("last_reason")

    job_id = job.get("job_id") or ""
    rec = job.get("recipient") or {}
    src = job.get("source") or {}

    y = h - 60
    c.setFont("Helvetica-Bold", 20)
    c.drawString(50, y, "Fax-Sendebericht")
    y -= 35

    c.setFont("Helvetica-Bold", 16)
    c.drawString(50, y, f"Status: {status}")
    y -= 24

    c.setFont("Helvetica", 11)
    c.drawString(50, y, f"Job-ID: {job_id}")
    y -= 16
    c.drawString(50, y, f"Empfänger: {rec.get('name','')}  |  Nummer: {rec.get('number','')}")
    y -= 16
    c.drawString(50, y, f"Quelle: {src.get('src','')}  |  Datei: {src.get('filename_original','')}")
    y -= 20

    c.drawString(50, y, f"Dialstatus: {dial}  |  Hangupcause: {hcause}")
    y -= 16
    c.drawString(50, y, f"Faxstatus: {faxst}  |  Faxerror: {faxerr}")
    y -= 16
    if pages_raw:
        c.drawString(50, y, f"Seiten: {pages_raw}")
        y -= 16
    if reason:
        c.drawString(50, y, f"Grund: {reason}")
        y -= 16

    if a_cur is not None or a_max is not None or a_last:
        c.drawString(50, y, f"Attempt: current={a_cur} max={a_max} last_reason={a_last or ''}")
        y -= 16

    if r_max is not None or r_next or r_last:
        c.drawString(50, y, f"Retry: max={r_max} last_reason={r_last or ''}")
        y -= 16
        if r_next:
            c.drawString(50, y, f"Next try at (UTC): {r_next}")
            y -= 16

    c.setFont("Helvetica", 9)
    c.drawString(50, 40, f"Erzeugt: {now_iso()}  |  kienzlefax-worker v1.3.6")
    c.showPage()
    c.save()

class AmiError(Exception):
    pass

def ami_send(sockf, line: str) -> None:
    sockf.write((line.rstrip("\r\n") + "\r\n").encode("utf-8", errors="ignore"))

def ami_read_response(sockf) -> str:
    buf = bytearray()
    while True:
        line = sockf.readline()
        if not line:
            break
        buf += line
        if line in (b"\r\n", b"\n"):
            break
    return buf.decode("utf-8", errors="replace")

def ami_login(sockf) -> None:
    ami_send(sockf, "Action: Login")
    ami_send(sockf, f"Username: {AMI_USER}")
    ami_send(sockf, f"Secret: {AMI_PASS}")
    ami_send(sockf, "Events: off")
    ami_send(sockf, "")
    r = ami_read_response(sockf)
    if "Response: Success" not in r:
        raise AmiError(f"AMI login failed: {r.strip()}")

def ami_logoff(sockf) -> None:
    try:
        ami_send(sockf, "Action: Logoff")
        ami_send(sockf, "")
        _ = ami_read_response(sockf)
    except Exception:
        pass

def ami_core_show_channels() -> str:
    if not AMI_PASS:
        raise AmiError("AMI password missing (KFX_AMI_PASS)")
    s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
    sockf = s.makefile("rwb", buffering=0)
    try:
        _ = sockf.readline()
        ami_login(sockf)
        ami_send(sockf, "Action: CoreShowChannels")
        ami_send(sockf, "ActionID: kfx-core")
        ami_send(sockf, "")
        buf = []
        complete_seen = False
        while True:
            line = sockf.readline()
            if not line:
                break
            t = line.decode("utf-8", errors="replace")
            buf.append(t)
            if "Event: CoreShowChannelsComplete" in t:
                complete_seen = True
            if complete_seen and t.strip() == "":
                break
        return "".join(buf)
    finally:
        try:
            ami_logoff(sockf)
        finally:
            try: sockf.close()
            except Exception: pass
            try: s.close()
            except Exception: pass

def ami_hangup_channel(channel: str) -> bool:
    if not AMI_PASS:
        raise AmiError("AMI password missing (KFX_AMI_PASS)")
    channel = (channel or "").strip()
    if not channel:
        return False
    s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
    sockf = s.makefile("rwb", buffering=0)
    try:
        _ = sockf.readline()
        ami_login(sockf)
        ami_send(sockf, "Action: Hangup")
        ami_send(sockf, f"Channel: {channel}")
        ami_send(sockf, "")
        r = ami_read_response(sockf)
        return ("Response: Success" in r)
    finally:
        try:
            ami_logoff(sockf)
        finally:
            try: sockf.close()
            except Exception: pass
            try: s.close()
            except Exception: pass

def ami_originate_local(jobid: str, exten: str, tiff_path: str) -> None:
    if not AMI_PASS:
        raise AmiError("AMI password missing (KFX_AMI_PASS)")

    action_id = f"kfx-{jobid}"
    channel = f"Local/{exten}@{DIAL_CONTEXT}/n"

    s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
    sockf = s.makefile("rwb", buffering=0)
    try:
        _ = sockf.readline()
        ami_login(sockf)

        ami_send(sockf, "Action: Originate")
        ami_send(sockf, f"ActionID: {action_id}")
        ami_send(sockf, f"Channel: {channel}")
        ami_send(sockf, "Async: true")

        ami_send(sockf, "Application: Wait")
        ami_send(sockf, f"Data: {AMI_ORIGINATE_WAIT_SEC}")

        ami_send(sockf, f"Variable: KFX_JOBID={jobid}")
        ami_send(sockf, f"Variable: KFX_FILE={tiff_path}")
        ami_send(sockf, "")

        r = ami_read_response(sockf)
        if "Response: Success" not in r:
            raise AmiError(f"AMI originate failed: {r.strip()}")
    finally:
        try:
            ami_logoff(sockf)
        finally:
            try: sockf.close()
            except Exception: pass
            try: s.close()
            except Exception: pass

def prepare_send_files(jobdir: Path, job: Dict[str, Any]) -> Tuple[Path, Path]:
    pdf_in = find_original_pdf_in_jobdir(jobdir)
    if not pdf_in:
        raise RuntimeError("missing doc.pdf/source.pdf")
    pdf_for_archive = add_header_pdf(pdf_in)
    tiff = jobdir / "doc.tif"
    if (not tiff.exists()) or (tiff.stat().st_size == 0):
        pdf_to_tiff_g4(pdf_for_archive, tiff)
    return pdf_for_archive, tiff

def _attempt_limit_reached(job: Dict[str, Any]) -> bool:
    a = job.get("attempt") or {}
    r = job.get("retry") or {}
    try:
        cur = int(a.get("current") or 0)
    except Exception:
        cur = 0
    mx = a.get("max", r.get("max"))
    try:
        mx_int = int(mx) if mx is not None else 0
    except Exception:
        mx_int = 0
    return (mx_int > 0 and cur > mx_int)

def submit_job(jobdir: Path) -> None:
    global _next_submit_ts
    jp = jobdir / "job.json"
    if not jp.exists():
        log(f"submit: missing job.json in {jobdir}")
        return

    job = read_json(jp)

    if bool((job.get("cancel") or {}).get("requested")):
        job["status"] = "FAILED"
        job.setdefault("result", {})["reason"] = "cancelled"
        job["end_time"] = now_iso()
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]
        write_json(jp, job)
        return

    if _attempt_limit_reached(job):
        job["status"] = "FAILED"
        job.setdefault("result", {})["reason"] = "max attempts reached"
        job["finalized_at"] = job.get("finalized_at") or now_iso()
        job["end_time"] = job.get("end_time") or job["finalized_at"]
        write_json(jp, job)
        return

    rec = job.get("recipient") or {}
    number = normalize_number(rec.get("number") or "")
    if not number:
        raise RuntimeError("invalid recipient number")

    pdf_for_archive, tiff = prepare_send_files(jobdir, job)

    job["claimed_at"] = job.get("claimed_at") or now_iso()
    job["submitted_at"] = now_iso()
    job["started_at"] = job.get("started_at") or job["submitted_at"]

    a = job.setdefault("attempt", {})
    try:
        prev = int(a.get("current") or 0)
    except Exception:
        prev = 0
    a["current"] = prev + 1
    a["started_at"] = job["submitted_at"]

    r = job.get("retry") or {}
    if r.get("max") is not None:
        try:
            a["max"] = int(r.get("max"))
        except Exception:
            pass
    if r.get("last_reason"):
        a["last_reason"] = str(r.get("last_reason"))

    job["status"] = "CALLING"
    job["updated_at"] = job["submitted_at"]

    job.setdefault("asterisk", {})
    job["asterisk"]["dial_context"] = DIAL_CONTEXT
    job["asterisk"]["exten"] = number
    job["asterisk"]["tiff"] = str(tiff)
    job["asterisk"]["pdf_for_archive"] = str(pdf_for_archive)
    job["asterisk"]["accountcode"] = str(job.get("job_id") or jobdir.name)
    job["asterisk"]["cdr_userfield"] = f"kfx:{job.get('job_id') or jobdir.name}"

    write_json(jp, job)

    try:
        ami_originate_local(jobid=str(job.get("job_id") or jobdir.name),
                            exten=number,
                            tiff_path=str(tiff))
        log(f"submitted via AMI -> {jobdir.name} exten={number} attempt={a.get('current')} wait={AMI_ORIGINATE_WAIT_SEC}s")
    except Exception as e:
        job = read_json(jp)
        job["status"] = "FAILED"
        job.setdefault("result", {})["reason"] = f"ami_originate_failed: {e}"
        job["end_time"] = now_iso()
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]
        write_json(jp, job)
        log(f"submit failed for {jobdir.name}: {e}")
        _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC

def finalize_ok(jobdir: Path, job: Dict[str, Any]) -> None:
    safe_mkdir(ARCH_OK)
    src = job.get("source") or {}
    base = sanitize_basename(Path(src.get("filename_original") or "fax").stem)
    jobid = job.get("job_id") or jobdir.name

    report_pdf = jobdir / "report.pdf"
    merged_pdf = jobdir / "merged.pdf"

    pdf_for_archive = Path((job.get("asterisk") or {}).get("pdf_for_archive") or "")
    if not pdf_for_archive.exists():
        pdf_for_archive = find_original_pdf_in_jobdir(jobdir) or (jobdir / "doc.pdf")

    build_report_pdf(job, report_pdf)
    merge_report_and_doc(report_pdf, pdf_for_archive, merged_pdf)

    out_pdf = ARCH_OK / f"{base}__{jobid}__OK.pdf"
    out_json = ARCH_OK / f"{base}__{jobid}.json"
    shutil.move(str(merged_pdf), str(out_pdf))
    write_json(out_json, job)
    log(f"finalize OK -> {out_pdf.name}")

def finalize_failed(jobdir: Path, job: Dict[str, Any]) -> None:
    safe_mkdir(FAIL_OUT)
    try:
        copy_original_to_fail_in(jobdir, job)
    except Exception as e:
        log(f"fail: copy original failed: {e}")

    src = job.get("source") or {}
    base = sanitize_basename(Path(src.get("filename_original") or "fax").stem)
    jobid = job.get("job_id") or jobdir.name

    report_pdf = jobdir / "report.pdf"
    merged_pdf = jobdir / "merged.pdf"

    pdf_for_archive = Path((job.get("asterisk") or {}).get("pdf_for_archive") or "")
    if not pdf_for_archive.exists():
        pdf_for_archive = find_original_pdf_in_jobdir(jobdir) or (jobdir / "doc.pdf")

    build_report_pdf(job, report_pdf)
    merge_report_and_doc(report_pdf, pdf_for_archive, merged_pdf)

    out_pdf = FAIL_OUT / f"{base}__{jobid}__FAILED.pdf"
    out_json = FAIL_OUT / f"{base}__{jobid}.json"
    shutil.move(str(merged_pdf), str(out_pdf))
    write_json(out_json, job)
    log(f"finalize FAILED -> {out_pdf.name}")

def requeue_retry(jobdir: Path, job: Dict[str, Any]) -> None:
    job["status"] = "RETRY_WAIT"
    job["updated_at"] = now_iso()
    write_json(jobdir / "job.json", job)

    target = QUEUE / jobdir.name
    try:
        jobdir.rename(target)
        r = job.get("retry") or {}
        a = job.get("attempt") or {}
        try:
            cur = int(a.get("current") or 0)
        except Exception:
            cur = 0
        log(
            f"retry scheduled attempt={a.get('current','?')}/{a.get('max', r.get('max','?'))} "
            f"(next_attempt={cur+1}) reason={r.get('last_reason','')} next_try_at={r.get('next_try_at','')} -> {target.name}"
        )
    except Exception as e:
        log(f"retry move back to queue failed for {jobdir.name}: {e}")

def _job_is_active_calling(job: Dict[str, Any]) -> bool:
    # konservativ: Status-Timing kann variieren; Cancel soll trotzdem greifen
    st = str(job.get("status") or "").strip().lower()
    return st in ("processing", "submitted", "calling", "sending")

def _find_channels_for_job(jobid: str) -> List[str]:
    try:
        txt = ami_core_show_channels()
    except Exception as e:
        log(f"cancel: CoreShowChannels failed: {e}")
        txt = ""

    chans: List[str] = []
    if txt:
        cur_chan = None
        cur_acc = None
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                if cur_chan and cur_acc == jobid:
                    chans.append(cur_chan)
                cur_chan = None
                cur_acc = None
                continue
            if line.startswith("Channel:"):
                cur_chan = line.split(":",1)[1].strip()
            elif line.startswith("AccountCode:"):
                cur_acc = line.split(":",1)[1].strip()

        if cur_chan and cur_acc == jobid:
            chans.append(cur_chan)

    if not chans:
        try:
            rc, so, _ = run_cmd(["asterisk","-rx","core show channels concise"])
            if rc == 0 and so:
                for ln in so.splitlines():
                    if jobid in ln:
                        ch = ln.split("!",1)[0].strip()
                        if ch:
                            chans.append(ch)
        except Exception:
            pass

    out=[]
    for c in chans:
        if c not in out:
            out.append(c)
    return out

def step_cancel_processing() -> None:
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue

        c = job.get("cancel") or {}
        if not bool(c.get("requested")):
            continue

        jobid = str(job.get("job_id") or jdir.name)

        if str(job.get("status") or "").upper() in ("CANCELLED", "FAILED", "OK"):
            continue

        if _job_is_active_calling(job):
            chans = _find_channels_for_job(jobid)
            if chans:
                pref = [x for x in chans if x.startswith("PJSIP/")] + [x for x in chans if x.startswith("Local/")] + chans
                done = False
                for ch in pref:
                    try:
                        if ami_hangup_channel(ch):
                            log(f"cancel: hangup sent jobid={jobid} channel={ch}")
                            done = True
                            break
                    except Exception as e:
                        log(f"cancel: hangup error jobid={jobid} channel={ch}: {e}")
                if not done:
                    log(f"cancel: no hangup success jobid={jobid} chans={chans}")
            else:
                log(f"cancel: no channels found jobid={jobid} (will rely on timeout/orphan)")

            job.setdefault("cancel", {})
            job["cancel"]["handled_at"] = now_iso()
            job["updated_at"] = now_iso()
            write_json(jp, job)
            continue

        job["status"] = "CANCELLED"
        job.setdefault("result", {})["reason"] = "cancelled"
        job.setdefault("cancel", {})
        job["cancel"]["handled_at"] = now_iso()
        job["end_time"] = now_iso()
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]
        job["updated_at"] = job["end_time"]
        write_json(jp, job)
        log(f"cancel: finalized CANCELLED jobid={jobid}")

def step_finalize_processing() -> None:
    global _next_submit_ts
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue

        st = _st_norm(job)

        if st == "OK":
            try:
                if not job.get("finalized_at"):
                    job["finalized_at"] = now_iso()
                job["end_time"] = job.get("end_time") or job["finalized_at"]
                write_json(jp, job)
                finalize_ok(jdir, job)
            except Exception as e:
                log(f"finalize OK exception {jdir.name}: {e}")
            shutil.rmtree(jdir, ignore_errors=True)
            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

        if st == "FAILED":
            try:
                if not job.get("finalized_at"):
                    job["finalized_at"] = now_iso()
                job["end_time"] = job.get("end_time") or job["finalized_at"]
                write_json(jp, job)
                finalize_failed(jdir, job)
            except Exception as e:
                log(f"finalize FAILED exception {jdir.name}: {e}")
            shutil.rmtree(jdir, ignore_errors=True)
            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

        if st in ("RETRY", "RETRY_WAIT"):
            try:
                if _attempt_limit_reached(job):
                    job["status"] = "FAILED"
                    job.setdefault("result", {})
                    base_reason = str((job.get("result") or {}).get("reason") or "RETRY")
                    mx = (job.get("attempt") or {}).get("max", (job.get("retry") or {}).get("max"))
                    job["result"]["reason"] = f"{base_reason} (max attempts reached: {mx})"
                    job["finalized_at"] = job.get("finalized_at") or now_iso()
                    job["end_time"] = job.get("end_time") or job["finalized_at"]
                    write_json(jp, job)
                    finalize_failed(jdir, job)
                    shutil.rmtree(jdir, ignore_errors=True)
                    _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
                    continue

                requeue_retry(jdir, job)
            except Exception as e:
                log(f"requeue exception {jdir.name}: {e}")

            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

def step_submit() -> None:
    global _next_submit_ts
    if time.time() < _next_submit_ts:
        return

    inflight = count_inflight()
    if inflight >= MAX_INFLIGHT_PROCESSING:
        return

    busy = get_busy_numbers()
    while inflight < MAX_INFLIGHT_PROCESSING:
        jdir = claim_next_job_skipping_busy(busy)
        if not jdir:
            return

        jp = jdir / "job.json"
        try:
            job = read_json(jp)
            job["claimed_at"] = job.get("claimed_at") or now_iso()
            if not job.get("status"):
                job["status"] = "PROCESSING"
            job["updated_at"] = now_iso()
            write_json(jp, job)

            num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
            if num:
                busy.add(num)
        except Exception:
            pass

        try:
            submit_job(jdir)
        except Exception as e:
            log(f"submit exception {jdir.name}: {e}")
            try:
                job = read_json(jp)
                job["status"] = "FAILED"
                job.setdefault("result", {})["reason"] = f"submit_exception: {e}"
                job["end_time"] = now_iso()
                job["finalized_at"] = job.get("finalized_at") or job["end_time"]
                write_json(jp, job)
            except Exception:
                pass

        inflight = count_inflight()

def main() -> None:
    ensure_dirs()
    acquire_lock()
    log("started (v1.3.6)")
    try:
        while True:
            step_cancel_processing()
            step_finalize_processing()
            step_submit()
            time.sleep(POLL_INTERVAL_SEC)
    finally:
        release_lock()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("stopped by user")
        sys.exit(0)
PY

chmod +x /usr/local/bin/kienzlefax-worker.py


sudo bash -euxo pipefail <<'EOF'
# ===== kienzlefax-worker systemd service installieren + aktivieren =====

# 1) Plausibilitätschecks
test -x /usr/local/bin/kienzlefax-worker.py
id asterisk >/dev/null 2>&1 || true

# 2) Optional: eigener User (falls du NICHT als root laufen willst)
#    (empfohlen ist: als "asterisk" laufen, damit AMI/Dateirechte sauber sind)
#    Wenn der User bei dir anders ist, hier anpassen:
RUN_AS_USER="root"
RUN_AS_GROUP="root"

# 3) Service-Datei schreiben
sudo tee /etc/systemd/system/kienzlefax-worker.service >/dev/null <<SERVICE
[Unit]
Description=kienzlefax worker (Asterisk SendFAX via AMI)
After=network.target asterisk.service
Wants=asterisk.service

[Service]
Type=simple
User=${RUN_AS_USER}
Group=${RUN_AS_GROUP}
WorkingDirectory=/srv/kienzlefax
ExecStart=/usr/bin/python3 -u /usr/local/bin/kienzlefax-worker.py
Restart=always
RestartSec=2

# --- Environment: bei Bedarf hier setzen/ändern ---
Environment=KFX_BASE=/srv/kienzlefax
Environment=KFX_AMI_HOST=127.0.0.1
Environment=KFX_AMI_PORT=5038
Environment=KFX_AMI_USER=kfx
Environment=KFX_AMI_PASS=test
Environment=KFX_DIAL_CONTEXT=fax-out
Environment=KFX_MAX_INFLIGHT=1
Environment=KFX_POLL_INTERVAL_SEC=1.0
Environment=KFX_POST_CALL_COOLDOWN_SEC=20.0
Environment=KFX_AMI_ORIGINATE_WAIT_SEC=3600
Environment=KFX_PDF_HEADER_SCRIPT=/usr/local/bin/pdf_with_header.sh
Environment=KFX_QPDF_BIN=qpdf
Environment=KFX_GS_BIN=gs
Environment=KFX_TIFF_DPI=204x196
Environment=KFX_TIFF_DEVICE=tiffg4

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

# 4) Rechte sicherstellen (wichtig, falls als asterisk läuft)
sudo mkdir -p /srv/kienzlefax/{queue,processing,sendeberichte,sendefehler/eingang,sendefehler/berichte}
#sudo chown -R ${RUN_AS_USER}:${RUN_AS_GROUP} /srv/kienzlefax
sudo chmod -R u+rwX,g+rwX /srv/kienzlefax

# 5) systemd reload + enable + start
sudo systemctl daemon-reload
sudo systemctl enable --now kienzlefax-worker.service

# 6) Status anzeigen
sudo systemctl status kienzlefax-worker --no-pager -l

# 7) Live-Logs (kurz)
sudo journalctl -u kienzlefax-worker -n 80 --no-pager
EOF



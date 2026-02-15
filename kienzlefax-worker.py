#!/usr/bin/env python3
# kienzlefax-worker.py
# Version 1.2.4
#
# Changes (minimal, agreed):
# 1) Live-Status-Felder aus `faxstat -sal` in job.json:
#    job["live"] = {
#      "updated_at": ISO8601,
#      "progress": {"sent": int, "total": int, "raw": "6:32"},
#      "dials":    {"done": int, "max": int, "raw": "1:12"},
#      "tts": "…",
#      "state": "R",
#      "faxstat_status": "…"
#    }
#    -> Nur für Jobs in processing/ mit hylafax.jid.
#    -> `faxstat` wird NUR abgefragt, wenn mindestens ein aktiver HylaFAX-Job existiert,
#       und dann maximal alle FAXSTAT_REFRESH_SEC Sekunden.
#
# 2) Lock reboot-sicher: statt "Lockfile existiert" wird ein Kernel-Lock via flock genutzt.
#    Die Datei darf existieren; blockiert nur, wenn ein Prozess den Lock hält.

import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

# ----------------------------
# Config
# ----------------------------
BASE = Path("/srv/kienzlefax")
QUEUE = BASE / "queue"
PROC = BASE / "processing"
ARCH_OK = BASE / "sendeberichte"
FAIL_IN = BASE / "sendefehler" / "eingang"
FAIL_OUT = BASE / "sendefehler" / "berichte"

HYLAFAX_DONEQ = Path("/var/spool/hylafax/doneq")

SEND_FAX_BIN = "sendfax"
FAXRM_BIN = "faxrm"
FAXSTAT_BIN = "faxstat"

FAX_HOST = "localhost"
FAXUSER = "faxworker"

PDF_HEADER_SCRIPT = Path("/usr/local/bin/pdf_with_header.sh")  # optional
QPDF_BIN = "qpdf"

# concurrency knobs
MAX_INFLIGHT_PROCESSING = 2
POLL_INTERVAL_SEC = 1.0
FAXSTAT_REFRESH_SEC = 2.0
FINALIZE_TIMEOUT_SEC = 60 * 30
SEND_TIMEOUT_SEC = 30
FAXRM_TIMEOUT_SEC = 30
CANCEL_POSTWAIT_SEC = 3

# lockfile (reboot-safe via flock)
LOCKFILE = BASE / ".kienzlefax-worker.lock"

LOG_PREFIX = "kienzlefax-worker"

_lock_fd: Optional[int] = None
_last_faxstat_ts: float = 0.0
_last_faxstat_rows: Dict[int, Dict[str, str]] = {}


# ----------------------------
# Helpers
# ----------------------------
def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def log(msg: str) -> None:
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"[{ts}] {LOG_PREFIX}: {msg}", flush=True)

def read_json(p: Path) -> Dict[str, Any]:
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)

def write_json(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, p)

def safe_mkdir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)

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

def list_jobdirs(root: Path) -> list[Path]:
    if not root.exists():
        return []
    dirs = [p for p in root.iterdir() if p.is_dir()]
    dirs.sort(key=lambda x: x.name)
    return dirs

def parse_sendfax_jid(out: str, err: str) -> Optional[int]:
    m = re.search(r"request id is\s+(\d+)", out or "")
    if m:
        return int(m.group(1))
    m = re.search(r"request id is\s+(\d+)", err or "")
    if m:
        return int(m.group(1))
    return None

def run_cmd(cmd: list[str], *, env: Optional[dict]=None, timeout: Optional[int]=None) -> Tuple[int, str, str]:
    p = subprocess.run(
        cmd,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return p.returncode, (p.stdout or ""), (p.stderr or "")

def add_header(pdf: Path) -> Path:
    if not PDF_HEADER_SCRIPT.exists():
        return pdf
    out = pdf.with_name(pdf.stem + "_hdr.pdf")
    try:
        subprocess.run(
            [str(PDF_HEADER_SCRIPT), str(pdf), str(out)],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if out.exists() and out.stat().st_size > 0:
            return out
    except Exception as e:
        log(f"header script failed -> sending without header: {e}")
    return pdf

def merge_report_and_doc(report_pdf: Path, doc_pdf: Path, out_pdf: Path) -> None:
    cmd = [QPDF_BIN, "--empty", "--pages", str(report_pdf), str(doc_pdf), "--", str(out_pdf)]
    rc, so, se = run_cmd(cmd)
    if rc != 0:
        raise RuntimeError(f"qpdf merge failed rc={rc} out={so.strip()} err={se.strip()}")

def parse_ratio(s: str) -> Tuple[Optional[int], Optional[int]]:
    s = (s or "").strip()
    m = re.fullmatch(r"(\d+)\s*:\s*(\d+)", s)
    if not m:
        return None, None
    return int(m.group(1)), int(m.group(2))


# ----------------------------
# faxstat live parsing
# ----------------------------
def parse_faxstat_sal(text: str) -> Dict[int, Dict[str, str]]:
    """
    Parses `faxstat -sal` table into:
      { jid: { "jid","pri","state","owner","number","pages","dials","tts","status" } }
    """
    rows: Dict[int, Dict[str, str]] = {}
    lines = (text or "").splitlines()

    # find header line starting with "JID"
    start = None
    for i, ln in enumerate(lines):
        if ln.strip().startswith("JID"):
            start = i + 1
            break
    if start is None:
        return rows

    for ln in lines[start:]:
        if not ln.strip():
            continue
        toks = ln.split()
        if len(toks) < 7:
            continue

        jid_s = toks[0]
        if not jid_s.isdigit():
            continue

        jid = int(jid_s)
        pri = toks[1] if len(toks) > 1 else ""
        state = toks[2] if len(toks) > 2 else ""
        owner = toks[3] if len(toks) > 3 else ""
        number = toks[4] if len(toks) > 4 else ""
        pages = toks[5] if len(toks) > 5 else ""
        dials = toks[6] if len(toks) > 6 else ""
        tts = toks[7] if len(toks) > 7 else ""
        status = " ".join(toks[8:]) if len(toks) > 8 else ""

        rows[jid] = {
            "jid": str(jid),
            "pri": pri,
            "state": state,
            "owner": owner,
            "number": number,
            "pages": pages,
            "dials": dials,
            "tts": tts,
            "status": status,
        }
    return rows

def has_active_hylafax_jobs() -> bool:
    """
    Only poll faxstat if at least one processing job has a JID and is not finalized.
    """
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        hy = job.get("hylafax") or {}
        if not hy.get("jid"):
            continue
        if job.get("finalized_at") or job.get("end_time"):
            continue
        return True
    return False

def refresh_faxstat_cache_if_needed() -> None:
    global _last_faxstat_ts, _last_faxstat_rows

    if not has_active_hylafax_jobs():
        return

    now = time.time()
    if (now - _last_faxstat_ts) < FAXSTAT_REFRESH_SEC and _last_faxstat_rows:
        return

    env = os.environ.copy()
    env["FAXUSER"] = FAXUSER

    # -a (all jobs), -l (long), -s (sendq status). User wanted -sal style.
    cmd = [FAXSTAT_BIN, "-sal", "-h", FAX_HOST]
    rc, so, se = run_cmd(cmd, env=env, timeout=10)
    if rc != 0:
        # Keep old cache; log once per refresh attempt
        log(f"faxstat failed rc={rc} err='{se.strip()}' out='{so.strip()}'")
        _last_faxstat_ts = now
        return

    _last_faxstat_rows = parse_faxstat_sal(so)
    _last_faxstat_ts = now

def update_processing_jobs_live() -> None:
    """
    Updates job.json live fields for processing jobs with a jid.
    Only writes when a faxstat row for that jid exists.
    """
    refresh_faxstat_cache_if_needed()
    if not _last_faxstat_rows:
        return

    updated_at = now_iso()

    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue

        hy = job.get("hylafax") or {}
        jid = hy.get("jid")
        if not isinstance(jid, int):
            # sometimes jid stored as string
            try:
                jid = int(jid)
            except Exception:
                continue

        row = _last_faxstat_rows.get(jid)
        if not row:
            continue

        sent, total = parse_ratio(row.get("pages", ""))
        d_done, d_max = parse_ratio(row.get("dials", ""))

        live = job.setdefault("live", {})
        live["updated_at"] = updated_at
        live["progress"] = {"sent": sent if sent is not None else 0,
                            "total": total if total is not None else 0,
                            "raw": row.get("pages", "")}
        live["dials"] = {"done": d_done if d_done is not None else 0,
                         "max": d_max if d_max is not None else 0,
                         "raw": row.get("dials", "")}
        live["tts"] = row.get("tts", "")
        live["state"] = row.get("state", "")
        live["faxstat_status"] = row.get("status", "")

        try:
            write_json(jp, job)
        except Exception as e:
            log(f"live update failed for {jdir.name}: {e}")


# ----------------------------
# Doneq parsing + report
# ----------------------------
@dataclass
class DoneqInfo:
    statuscode: Optional[int] = None
    npages: Optional[int] = None
    totpages: Optional[int] = None
    signalrate: Optional[str] = None
    csi: Optional[str] = None
    commid: Optional[str] = None
    tts: Optional[int] = None
    returned: Optional[int] = None
    raw: Dict[str, str] = None

def parse_doneq_file(qfile: Path) -> DoneqInfo:
    raw: Dict[str, str] = {}
    with qfile.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or ":" not in line:
                continue
            k, v = line.split(":", 1)
            raw[k.strip()] = v.strip()

    def geti(k: str) -> Optional[int]:
        v = raw.get(k)
        if v is None or v == "":
            return None
        try:
            return int(v)
        except:
            return None

    return DoneqInfo(
        statuscode=geti("statuscode"),
        npages=geti("npages"),
        totpages=geti("totpages"),
        signalrate=raw.get("signalrate"),
        csi=raw.get("csi"),
        commid=raw.get("commid"),
        tts=geti("tts"),
        returned=geti("returned"),
        raw=raw,
    )

def build_report_pdf(job: Dict[str, Any], doneq: Optional[DoneqInfo], out_pdf: Path) -> None:
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(str(out_pdf), pagesize=A4)
    w, h = A4

    was_cancelled = bool((job.get("cancel") or {}).get("requested"))
    status = (job.get("status") or "").upper()
    if was_cancelled:
        status_label = "CANCELLED (abgebrochen)"
    elif status == "OK":
        status_label = "OK (erfolgreich)"
    elif status == "FAILED":
        status_label = "FAILED (fehlgeschlagen)"
    else:
        status_label = status or "UNKNOWN"

    job_id = job.get("job_id") or ""
    rec = job.get("recipient") or {}
    src = job.get("source") or {}
    opts = job.get("options") or {}
    hy = job.get("hylafax") or {}

    y = h - 60
    c.setFont("Helvetica-Bold", 20)
    c.drawString(50, y, "Fax-Sendebericht")
    y -= 35

    c.setFont("Helvetica-Bold", 16)
    c.drawString(50, y, f"Status: {status_label}")
    y -= 25

    c.setFont("Helvetica", 11)
    c.drawString(50, y, f"Job-ID: {job_id}")
    y -= 16
    c.drawString(50, y, f"Empfänger: {rec.get('name','')}  |  Nummer: {rec.get('number','')}")
    y -= 16
    c.drawString(50, y, f"Quelle: {src.get('src','')}  |  Datei: {src.get('filename_original','')}")
    y -= 16
    c.drawString(50, y, f"Optionen: ECM={opts.get('ecm')}  |  Auflösung={opts.get('resolution')}")
    y -= 22

    jid = hy.get("jid")
    c.drawString(50, y, f"HylaFAX JID: {jid if jid is not None else ''}")
    y -= 16

    if doneq:
        if doneq.commid:
            c.drawString(50, y, f"CommID: {doneq.commid}")
            y -= 16
        if doneq.csi:
            c.drawString(50, y, f"CSI: {doneq.csi}")
            y -= 16
        if doneq.signalrate:
            c.drawString(50, y, f"Signalrate: {doneq.signalrate}")
            y -= 16
        if doneq.npages is not None and doneq.totpages is not None:
            c.drawString(50, y, f"Seiten: {doneq.npages}/{doneq.totpages}")
            y -= 16

    started = job.get("started_at") or job.get("submitted_at") or job.get("claimed_at")
    ended = job.get("end_time") or job.get("finalized_at")
    if started and ended:
        try:
            s = datetime.fromisoformat(str(started).replace("Z", "+00:00"))
            e = datetime.fromisoformat(str(ended).replace("Z", "+00:00"))
            dur = int((e - s).total_seconds())
            c.drawString(50, y, f"Dauer: {dur} s")
            y -= 16
        except Exception:
            pass

    c.setFont("Helvetica", 9)
    c.drawString(50, 40, f"Erzeugt: {now_iso()}  |  kienzlefax-worker v1.2.4")
    c.showPage()
    c.save()


# ----------------------------
# Lock (reboot-safe)
# ----------------------------
def acquire_lock() -> None:
    global _lock_fd
    safe_mkdir(BASE)

    fd = os.open(str(LOCKFILE), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise SystemExit(f"{LOG_PREFIX}: already running (lock held: {LOCKFILE})")

    # write pid for humans (not used for logic)
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


# ----------------------------
# Cancel / job handling (unchanged behavior)
# ----------------------------
def cancel_requested(job: Dict[str, Any]) -> bool:
    c = job.get("cancel") or {}
    return bool(c.get("requested") is True)

def cancel_handled(job: Dict[str, Any]) -> bool:
    c = job.get("cancel") or {}
    return bool(c.get("handled_at"))

def mark_cancel_handled(job: Dict[str, Any]) -> None:
    c = job.setdefault("cancel", {})
    c["handled_at"] = now_iso()

def hylafax_cancel(jid: int) -> Tuple[int, str, str]:
    env = os.environ.copy()
    env["FAXUSER"] = FAXUSER
    cmd = [FAXRM_BIN, "-h", FAX_HOST, str(jid)]
    rc, so, se = run_cmd(cmd, env=env, timeout=FAXRM_TIMEOUT_SEC)
    return rc, so, se

def find_original_pdf_in_jobdir(jobdir: Path) -> Optional[Path]:
    cand1 = jobdir / "source.pdf"
    cand2 = jobdir / "doc.pdf"
    for c in (cand1, cand2):
        try:
            if c.exists() and c.stat().st_size > 0:
                return c
        except Exception:
            continue
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
    log(f"cancel/fail: original copied -> {dest.name}")

def write_failed_artifacts(jobdir: Path, job: Dict[str, Any], doneq: Optional[DoneqInfo]) -> None:
    safe_mkdir(FAIL_OUT)

    src = job.get("source") or {}
    base = sanitize_basename(Path(src.get("filename_original") or "fax").stem)
    jobid = job.get("job_id") or jobdir.name

    job["finalizing_at"] = job.get("finalizing_at") or now_iso()
    job["finalized_at"] = now_iso()
    job["end_time"] = job.get("end_time") or job["finalized_at"]

    job["status"] = "FAILED"
    job.setdefault("result", {})
    job["result"]["reason"] = job["result"].get("reason") or ("cancelled" if cancel_requested(job) else "unknown")

    report_pdf = jobdir / "report.pdf"
    merged_pdf = jobdir / "merged.pdf"

    doc = jobdir / "doc.pdf"
    send_doc = doc.with_name(doc.stem + "_hdr.pdf")
    merge_doc = send_doc if send_doc.exists() else doc

    build_report_pdf(job, doneq, report_pdf)
    merge_report_and_doc(report_pdf, merge_doc, merged_pdf)

    out_pdf = FAIL_OUT / f"{base}__{jobid}__FAILED.pdf"
    out_json = FAIL_OUT / f"{base}__{jobid}.json"

    shutil.move(str(merged_pdf), str(out_pdf))
    write_json(out_json, job)
    log(f"cancel/fail: written -> {out_pdf.name} + {out_json.name}")

def finalize_cancel_in_queue(jdir: Path) -> None:
    jp = jdir / "job.json"
    if not jp.exists():
        return

    job = read_json(jp)
    if not cancel_requested(job) or cancel_handled(job):
        return

    mark_cancel_handled(job)
    job["claimed_at"] = job.get("claimed_at") or now_iso()
    job["submitted_at"] = job.get("submitted_at") or job["claimed_at"]
    job["started_at"] = job.get("started_at") or job["claimed_at"]
    job["end_time"] = job.get("end_time") or now_iso()
    job.setdefault("result", {})
    job["result"]["reason"] = job["result"].get("reason") or "cancelled"

    try:
        copy_original_to_fail_in(jdir, job)
    except Exception as e:
        log(f"queue-cancel: copy original failed: {e}")

    try:
        write_failed_artifacts(jdir, job, doneq=None)
    except Exception as e:
        log(f"queue-cancel: write artifacts failed: {e}")
        try:
            write_json(jp, job)
        except Exception:
            pass
        return

    shutil.rmtree(jdir, ignore_errors=True)
    log(f"queue-cancel: removed jobdir {jdir.name}")

def handle_cancel_in_processing(jdir: Path) -> None:
    jp = jdir / "job.json"
    if not jp.exists():
        return
    try:
        job = read_json(jp)
    except Exception:
        return

    if not cancel_requested(job) or cancel_handled(job):
        return

    jid = (job.get("hylafax") or {}).get("jid")
    if jid:
        log(f"cancel requested -> faxrm jid={jid} job={job.get('job_id','')}")
        try:
            rc, so, se = hylafax_cancel(int(jid))
            log(f"faxrm rc={rc} out='{so.strip()}' err='{se.strip()}'")
        except subprocess.TimeoutExpired:
            log(f"faxrm timeout for jid={jid}")
        time.sleep(CANCEL_POSTWAIT_SEC)

    mark_cancel_handled(job)
    try:
        write_json(jp, job)
    except Exception as e:
        log(f"failed to write cancel.handled_at for {jdir.name}: {e}")


# ----------------------------
# Workflow: claim/submit/finalize
# ----------------------------
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
        st = (job.get("status") or "").lower()
        if st in ("claimed", "submitted", "running"):
            num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
            if num:
                busy.add(num)
    return busy

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
        st = (job.get("status") or "").lower()
        if st in ("submitted", "running"):
            n += 1
    return n

def claim_next_job_skipping_busy(busy_numbers: set[str]) -> Optional[Path]:
    for j in list_jobdirs(QUEUE):
        jp = j / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
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

def ensure_dirs() -> None:
    for p in (QUEUE, PROC, ARCH_OK, FAIL_IN, FAIL_OUT):
        safe_mkdir(p)

def submit_job(jobdir: Path) -> None:
    jp = jobdir / "job.json"
    doc = jobdir / "doc.pdf"
    if not jp.exists() or not doc.exists():
        log(f"submit: missing job.json or doc.pdf in {jobdir}")
        return

    job = read_json(jp)
    if cancel_requested(job):
        return

    send_doc = add_header(doc)

    rec = job.get("recipient") or {}
    number = normalize_number(rec.get("number") or "")
    if not number:
        log(f"submit: invalid number in {jobdir.name}")
        return

    cmd = [SEND_FAX_BIN, "-n", "-d", number, str(send_doc)]
    env = os.environ.copy()
    env["FAXUSER"] = FAXUSER

    job["claimed_at"] = job.get("claimed_at") or now_iso()
    job["submitted_at"] = now_iso()
    job["started_at"] = job.get("started_at") or job["submitted_at"]
    job["status"] = "submitted"
    write_json(jp, job)

    try:
        rc, so, se = run_cmd(cmd, env=env, timeout=SEND_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        job = read_json(jp)
        job["status"] = "FAILED"
        job.setdefault("hylafax", {})
        job["hylafax"]["sendfax_rc"] = -1
        job["hylafax"]["sendfax_out"] = ""
        job["hylafax"]["sendfax_err"] = "sendfax timeout"
        job.setdefault("result", {})
        job["result"]["reason"] = job["result"].get("reason") or "sendfax timeout"
        write_json(jp, job)
        log(f"submit: sendfax timeout for {jobdir.name}")
        return

    jid = parse_sendfax_jid(so, se)
    job = read_json(jp)
    job.setdefault("hylafax", {})
    job["hylafax"]["sendfax_rc"] = rc
    job["hylafax"]["sendfax_out"] = so.strip()
    job["hylafax"]["sendfax_err"] = se.strip()
    if jid is not None:
        job["hylafax"]["jid"] = jid
        log(f"submit: {jobdir.name} -> jid={jid}")
    else:
        log(f"submit: {jobdir.name} -> no jid parsed (rc={rc})")

    write_json(jp, job)

def finalize_job(jobdir: Path) -> bool:
    jp = jobdir / "job.json"
    doc = jobdir / "doc.pdf"
    if not jp.exists() or not doc.exists():
        return False

    job = read_json(jp)
    hy = job.get("hylafax") or {}
    jid = hy.get("jid")

    if jid is None:
        return False

    qfile = HYLAFAX_DONEQ / f"q{jid}"
    if not qfile.exists():
        claimed_at = job.get("claimed_at") or job.get("submitted_at")
        if claimed_at:
            try:
                s = datetime.fromisoformat(str(claimed_at).replace("Z", "+00:00"))
                if (datetime.now(timezone.utc) - s).total_seconds() > FINALIZE_TIMEOUT_SEC:
                    log(f"finalize: timeout waiting doneq for jid={jid} job={job.get('job_id','')}")
            except Exception:
                pass
        return False

    doneq = parse_doneq_file(qfile)

    job.setdefault("result", {})
    job["result"]["statuscode"] = doneq.statuscode
    job["result"]["npages"] = doneq.npages
    job["result"]["totpages"] = doneq.totpages
    job["result"]["signalrate"] = doneq.signalrate or ""
    job["result"]["csi"] = doneq.csi or ""
    job["result"]["commid"] = doneq.commid or ""
    job["result"]["tx_time"] = job["result"].get("tx_time") or ""

    job["finalizing_at"] = job.get("finalizing_at") or now_iso()
    job["finalized_at"] = now_iso()
    job["end_time"] = job.get("end_time") or job["finalized_at"]

    was_cancelled = bool((job.get("cancel") or {}).get("requested"))

    if was_cancelled:
        job["status"] = "FAILED"
        job["result"]["reason"] = job["result"].get("reason") or "cancelled"
        try:
            copy_original_to_fail_in(jobdir, job)
        except Exception as e:
            log(f"cancel finalize: copy original failed: {e}")
        write_failed_artifacts(jobdir, job, doneq)
        shutil.rmtree(jobdir, ignore_errors=True)
        return True

    if doneq.statuscode == 0:
        job["status"] = "OK"
        job["result"]["reason"] = "OK"
        src = job.get("source") or {}
        base = sanitize_basename(Path(src.get("filename_original") or "fax").stem)
        jobid = job.get("job_id") or jobdir.name

        report_pdf = jobdir / "report.pdf"
        merged_pdf = jobdir / "merged.pdf"
        send_doc = doc.with_name(doc.stem + "_hdr.pdf")
        merge_doc = send_doc if send_doc.exists() else doc

        build_report_pdf(job, doneq, report_pdf)
        merge_report_and_doc(report_pdf, merge_doc, merged_pdf)

        out_pdf = ARCH_OK / f"{base}__{jobid}__OK.pdf"
        out_json = ARCH_OK / f"{base}__{jobid}.json"
        safe_mkdir(ARCH_OK)
        shutil.move(str(merged_pdf), str(out_pdf))
        write_json(out_json, job)
        log(f"finalize OK -> {out_pdf.name}")
        shutil.rmtree(jobdir, ignore_errors=True)
        return True

    job["status"] = "FAILED"
    job["result"]["reason"] = job["result"].get("reason") or "unknown"
    try:
        copy_original_to_fail_in(jobdir, job)
    except Exception as e:
        log(f"fail finalize: copy original failed: {e}")
    write_failed_artifacts(jobdir, job, doneq)
    shutil.rmtree(jobdir, ignore_errors=True)
    return True


# ----------------------------
# Steps
# ----------------------------
def step_queue_cancels() -> None:
    for jdir in list_jobdirs(QUEUE):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        if cancel_requested(job) and not cancel_handled(job):
            finalize_cancel_in_queue(jdir)

def step_processing() -> None:
    # live update first (only when active sending)
    update_processing_jobs_live()

    for jdir in list_jobdirs(PROC):
        handle_cancel_in_processing(jdir)

    for jdir in list_jobdirs(PROC):
        try:
            finalize_job(jdir)
        except Exception as e:
            log(f"finalize exception {jdir.name}: {e}")

def step_submit() -> None:
    inflight = count_inflight()
    if inflight >= MAX_INFLIGHT_PROCESSING:
        return

    busy = get_busy_numbers()
    while inflight < MAX_INFLIGHT_PROCESSING:
        jdir = claim_next_job_skipping_busy(busy)
        if not jdir:
            return

        try:
            job = read_json(jdir / "job.json")
            job["claimed_at"] = job.get("claimed_at") or now_iso()
            if cancel_requested(job):
                target = QUEUE / jdir.name
                try:
                    jdir.rename(target)
                    log(f"claimed-but-cancelled -> moved back to queue: {target.name}")
                except Exception as e:
                    log(f"move back to queue failed for cancelled job {jdir.name}: {e}")
                return
            job["status"] = job.get("status") or "claimed"
            write_json(jdir / "job.json", job)
            num = normalize_number(((job.get("recipient") or {}).get("number") or ""))
            if num:
                busy.add(num)
        except Exception:
            pass

        submit_job(jdir)
        inflight = count_inflight()


# ----------------------------
# Main
# ----------------------------
def main() -> None:
    ensure_dirs()
    acquire_lock()
    log("started (v1.2.4)")
    try:
        while True:
            step_queue_cancels()
            step_processing()
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

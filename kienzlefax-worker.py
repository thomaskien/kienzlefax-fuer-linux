#!/usr/bin/env python3
# kienzlefax-worker.py
# Version 1.2.3
#
# Key behavior:
# - Jobs are submitted via HylaFAX sendfax, then finalized by reading /var/spool/hylafax/doneq/q<JID>
# - A "cancel" request ALWAYS results in an entry under:
#     /srv/kienzlefax/sendefehler/berichte/  (merged report+document + json)
#   and the original PDF is copied to:
#     /srv/kienzlefax/sendefehler/eingang/   (unchanged original, sendable)
#
# Cancel semantics:
# - cancel in queue/:   no HylaFAX; directly create report+merged and move to sendefehler/*
# - cancel in processing/: faxrm JID, wait 3s, then finalize from doneq; forced into sendefehler/*
#
# Note:
# - cancel.handled_at is set as idempotency marker (prevents repeated handling)
# - For cancelled jobs, job["status"] is set to "FAILED" and result.reason="cancelled"
#   (storage and UI can still use the cancel block to show "CANCELLED").

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

FAX_HOST = "localhost"
FAXUSER = "faxworker"

PDF_HEADER_SCRIPT = Path("/usr/local/bin/pdf_with_header.sh")  # optional
QPDF_BIN = "qpdf"

# concurrency knobs
MAX_INFLIGHT_PROCESSING = 2        # how many jobs may be "submitted/running" at once
POLL_INTERVAL_SEC = 1.0
FINALIZE_TIMEOUT_SEC = 60 * 30     # after 30min we only log, we don't delete
SEND_TIMEOUT_SEC = 30              # sendfax should return quickly with request id
FAXRM_TIMEOUT_SEC = 30             # cancel shouldn't hang forever
CANCEL_POSTWAIT_SEC = 3

# lockfile (avoid /run permission issues)
LOCKFILE = BASE / ".kienzlefax-worker.lock"

LOG_PREFIX = "kienzlefax-worker"


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
    """
    Calls /usr/local/bin/pdf_with_header.sh in.pdf out.pdf
    Returns out path. If script missing or fails -> returns original pdf.
    """
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

    # Friendly status label
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
    c.drawString(50, 40, f"Erzeugt: {now_iso()}  |  kienzlefax-worker v1.2.3")
    c.showPage()
    c.save()

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

def acquire_lock() -> None:
    try:
        fd = os.open(str(LOCKFILE), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        os.write(fd, str(os.getpid()).encode("ascii"))
        os.close(fd)
    except FileExistsError:
        raise SystemExit(f"{LOG_PREFIX}: already running (lock exists: {LOCKFILE})")

def release_lock() -> None:
    try:
        LOCKFILE.unlink(missing_ok=True)
    except Exception:
        pass


# ----------------------------
# Cancel logic + common "finalize to sendefehler"
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
    # Prefer source.pdf if present, else doc.pdf
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
    """
    Create report.pdf + merged.pdf and move both merged+json into FAIL_OUT.
    Always uses FAIL_OUT naming with __FAILED.pdf + .json.
    """
    safe_mkdir(FAIL_OUT)

    src = job.get("source") or {}
    base = sanitize_basename(Path(src.get("filename_original") or "fax").stem)
    jobid = job.get("job_id") or jobdir.name

    # Ensure timestamps for report duration
    job["finalizing_at"] = job.get("finalizing_at") or now_iso()
    job["finalized_at"] = now_iso()
    job["end_time"] = job.get("end_time") or job["finalized_at"]

    # Force status for storage
    job["status"] = "FAILED"
    job.setdefault("result", {})
    job["result"]["reason"] = job["result"].get("reason") or "cancelled" if cancel_requested(job) else job["result"].get("reason") or "unknown"

    report_pdf = jobdir / "report.pdf"
    merged_pdf = jobdir / "merged.pdf"

    # Use header'ed version if present (it might have been created for sending)
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
    """
    Cancel requested while still in queue/: no HylaFAX interaction.
    We still MUST place it under sendefehler/berichte and copy original to sendefehler/eingang.
    """
    jp = jdir / "job.json"
    if not jp.exists():
        return

    job = read_json(jp)

    if not cancel_requested(job) or cancel_handled(job):
        return

    # mark handled, ensure some timestamps for duration
    mark_cancel_handled(job)
    job["claimed_at"] = job.get("claimed_at") or now_iso()
    job["submitted_at"] = job.get("submitted_at") or job["claimed_at"]
    job["started_at"] = job.get("started_at") or job["claimed_at"]
    job["end_time"] = job.get("end_time") or now_iso()
    job.setdefault("result", {})
    job["result"]["reason"] = job["result"].get("reason") or "cancelled"

    # copy original to FAIL_IN
    try:
        copy_original_to_fail_in(jdir, job)
    except Exception as e:
        log(f"queue-cancel: copy original failed: {e}")

    # write report+merged+json to FAIL_OUT
    try:
        write_failed_artifacts(jdir, job, doneq=None)
    except Exception as e:
        log(f"queue-cancel: write artifacts failed: {e}")
        # If artifacts fail, do NOT delete the jobdir (avoid data loss)
        try:
            write_json(jp, job)
        except Exception:
            pass
        return

    # Remove jobdir from queue after successful materialization
    shutil.rmtree(jdir, ignore_errors=True)
    log(f"queue-cancel: removed jobdir {jdir.name}")


def handle_cancel_in_processing(jdir: Path) -> None:
    """
    If cancel requested and job has jid -> faxrm. Do NOT delete doneq/q<JID>.
    Set cancel.handled_at as idempotency marker.
    Finalization to sendefehler/berichte happens in finalize_job() once doneq/q<JID> exists.
    """
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
# Main workflow
# ----------------------------
def submit_job(jobdir: Path) -> None:
    jp = jobdir / "job.json"
    doc = jobdir / "doc.pdf"
    if not jp.exists() or not doc.exists():
        log(f"submit: missing job.json or doc.pdf in {jobdir}")
        return

    job = read_json(jp)

    # If cancel already requested before submit: do NOT submit.
    # We still must store it under sendefehler/berichte -> handled by finalize_cancel_in_queue
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
    """
    Finalize jobs that have a HylaFAX JID once doneq/q<JID> exists.
    Cancelled jobs are ALWAYS stored under sendefehler/berichte (forced),
    regardless of HylaFAX statuscode.
    """
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

    # Fill result info from doneq (always)
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

    # Decide storage:
    was_cancelled = bool((job.get("cancel") or {}).get("requested"))

    if was_cancelled:
        # ALWAYS go to sendefehler/berichte
        job["status"] = "FAILED"
        job["result"]["reason"] = job["result"].get("reason") or "cancelled"

        # Also place original under sendefehler/eingang
        try:
            copy_original_to_fail_in(jobdir, job)
        except Exception as e:
            log(f"cancel finalize: copy original failed: {e}")

        # Write merged report+doc + json under FAIL_OUT
        write_failed_artifacts(jobdir, job, doneq)
        shutil.rmtree(jobdir, ignore_errors=True)
        return True

    # Non-cancelled: regular OK/FAILED based on statuscode
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

    # FAILED (not cancelled)
    job["status"] = "FAILED"
    job["result"]["reason"] = job["result"].get("reason") or "unknown"

    try:
        copy_original_to_fail_in(jobdir, job)
    except Exception as e:
        log(f"fail finalize: copy original failed: {e}")

    write_failed_artifacts(jobdir, job, doneq)
    shutil.rmtree(jobdir, ignore_errors=True)
    return True


def step_queue_cancels() -> None:
    # Cancel in queue is finalized immediately into sendefehler/*
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
    # 1) handle cancel requests for jobs already in processing (faxrm)
    for jdir in list_jobdirs(PROC):
        handle_cancel_in_processing(jdir)

    # 2) finalize anything that has a doneq/q<JID>
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

        # If cancel is already requested, don't submit; it will be finalized into sendefehler.
        try:
            job = read_json(jdir / "job.json")
            job["claimed_at"] = job.get("claimed_at") or now_iso()
            if cancel_requested(job):
                # move it back to queue for queue-cancel finalization (consistent path)
                # (We do not want to keep it in processing and block inflight slots.)
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


def main() -> None:
    ensure_dirs()
    acquire_lock()
    log("started (v1.2.3)")
    try:
        while True:
            # Important order:
            # 1) finalize queue cancels immediately into sendefehler/*
            step_queue_cancels()
            # 2) handle processing cancels + finalize from doneq
            step_processing()
            # 3) submit new jobs
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

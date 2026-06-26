sudo tee /usr/local/bin/kienzlefax-worker.py >/dev/null <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kienzlefax-worker.py — Asterisk-Only Worker (SendFAX)
Version: 1.3.17
Stand:  2026-06-23
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
- 1.3.7:
  - Fallback für Jobs, die nach send_start in SENDING hängen bleiben:
    Wenn kein Asterisk-Kanal zum Job mehr aktiv ist und kein send_end geschrieben wurde,
    wird der Job nach Timeout konservativ als RETRY weitergeführt statt dauerhaft in processing zu bleiben.
- 1.3.8:
  - Cancel-Fix für verwaiste aktive Jobs:
    Wenn cancel.requested gesetzt ist, aber kein Asterisk-Kanal zum Job mehr existiert,
    wird der Job sofort als CANCELLED finalisiert statt im processing zu bleiben.
- 1.3.9:
  - Sicherheitsfix gegen Doppelversand:
    Verwaiste SENDING-Jobs mit ANSWER werden NICHT automatisch erneut gesendet,
    sondern terminal als FAILED/UNKNOWN_SENT_NO_SEND_END markiert.
- 1.3.10:
  - Finalizer behandelt CANCELLED als terminalen Status und räumt den Job aus processing.
- 1.3.11:
  - Verwaiste SENDING-Jobs mit DIALSTATUS=ANSWER und normalem Hangup werden als
    OK_ASSUMED_NO_SEND_END archiviert statt als Fehler, weil die Praxis zeigt:
    Fax ist versendet, nur send_end fehlt. Kein Retry, kein Doppelversand.
- 1.3.12:
  - Live-Details fuer aktive Asterisk-SendFAX-Sessions:
    aktuelle Seite aus `fax show session`, Gesamtseiten aus `tiffinfo doc.tif`,
    Datenrate, Session, Kanal und Call-Dauer werden in job.json unter
    live.asterisk_fax geschrieben.
- 1.3.13:
  - Live-Session-Erkennung robuster:
    Faxsessions werden ueber `fax show session <id>` und `File Name` dem Job zugeordnet,
    statt die Session-ID aus einer kanalabhaengigen Tabellenzeile ableiten zu muessen.
- 1.3.14:
  - FIX: `fax show sessions` auf Asterisk listet die Session-ID als Spalte FAXID,
    nicht zwingend am Zeilenanfang. Parser erkennt dieses Tabellenformat jetzt.
- 1.3.15:
  - Robustheit nach Stromausfall/Abbruch:
    - JSON-Schreibvorgaenge nutzen eindeutige Temp-Dateien plus fsync, damit parallele
      Worker-/AGI-Schreiber keine job.json-Reste oder Temp-Datei-Kollisionen erzeugen.
    - Kaputte oder fehlende job.json in processing wird nicht mehr ignoriert oder nur
      ausgelagert, sondern als FAILED in sendefehler/berichte abgelegt.
    - Verwaiste SENDING-Jobs ohne send_end werden als Fehlerbericht abgelegt, um
      unbemerkte Haenger und Doppelversand-Risiko zu vermeiden.
- 1.3.16:
  - Queue-Cancel wiederhergestellt:
    Jobs, die im Webinterface in queue abgebrochen werden, werden sofort als
    CANCELLED/cancelled in sendefehler/berichte abgelegt und aus queue entfernt.
- 1.3.17:
  - Fehlerbericht-Fallback:
    Wenn qpdf das Zusammenfuehren von Bericht und Original-PDF ablehnt, wird trotzdem
    ein Fehlerbericht-PDF mit JSON geschrieben. Das Original liegt separat im
    sendefehler/eingang, der Queue-Job wird nicht mehr blockiert.
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
from datetime import datetime, timezone, timedelta
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
ORPHAN_CALL_TIMEOUT_SEC = float(os.environ.get("KFX_ORPHAN_CALL_TIMEOUT_SEC", "120.0"))

# wichtig: Default 3600 wie im funktionierenden System
AMI_ORIGINATE_WAIT_SEC = int(os.environ.get("KFX_AMI_ORIGINATE_WAIT_SEC", "3600"))

ASTERISK_BIN = os.environ.get("KFX_ASTERISK_BIN", "asterisk")
TIFFINFO_BIN = os.environ.get("KFX_TIFFINFO_BIN", "tiffinfo")
FAX_LIVE_REFRESH_SEC = float(os.environ.get("KFX_FAX_LIVE_REFRESH_SEC", "2.0"))

TIFF_DPI = os.environ.get("KFX_TIFF_DPI", "204x196")
TIFF_DEVICE = os.environ.get("KFX_TIFF_DEVICE", "tiffg4")

LOCKFILE = BASE / ".kienzlefax-worker.lock"
LOG_PREFIX = "kienzlefax-worker"
_lock_fd: Optional[int] = None
_next_submit_ts: float = 0.0
_last_fax_live_ts: float = 0.0
_tiff_pages_cache: Dict[str, Tuple[float, Optional[int]]] = {}

def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def parse_iso_ts(value: Any) -> Optional[datetime]:
    s = str(value or "").strip()
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception:
        return None

def log(msg: str) -> None:
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"[{ts}] {LOG_PREFIX}: {msg}", flush=True)

def safe_mkdir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)

def read_json(p: Path) -> Dict[str, Any]:
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)

def write_json(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_name(f"{p.name}.tmp.{os.getpid()}.{time.time_ns()}")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
    try:
        dfd = os.open(str(p.parent), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except Exception:
        pass

def read_json_best_effort(p: Path) -> Tuple[Dict[str, Any], str]:
    try:
        return read_json(p), ""
    except Exception as strict_error:
        err = str(strict_error)

    try:
        raw = p.read_text(encoding="utf-8", errors="replace")
    except Exception as read_error:
        return {}, f"job.json unreadable: {read_error}"

    try:
        obj, end = json.JSONDecoder().raw_decode(raw.lstrip())
        if isinstance(obj, dict):
            tail = raw.lstrip()[end:].strip()
            if tail:
                return obj, f"job.json corrupt/trailing data after byte {end}: {err}"
            return obj, err
    except Exception:
        pass

    return {}, f"job.json invalid: {err}"

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

def _int_or_none(value: Any) -> Optional[int]:
    s = str(value or "").strip()
    if not s:
        return None
    m = re.search(r"-?\d+", s)
    if not m:
        return None
    try:
        return int(m.group(0))
    except Exception:
        return None

def _run_asterisk_rx(cmd: str, timeout: int = 5) -> str:
    try:
        rc, so, se = run_cmd([ASTERISK_BIN, "-rx", cmd], timeout=timeout)
    except Exception as e:
        log(f"fax live: asterisk command failed ({cmd}): {e}")
        return ""
    if rc != 0:
        err = (se or so or "").strip()
        if err:
            log(f"fax live: asterisk rc={rc} cmd={cmd} err={err}")
        return ""
    return so

def _active_sendfax_channels() -> List[str]:
    txt = _run_asterisk_rx("core show channels concise", timeout=5)
    out: List[str] = []
    for line in txt.splitlines():
        parts = line.split("!")
        if len(parts) < 6:
            continue
        app = parts[5].strip()
        if app.lower() != "sendfax":
            continue
        ch = parts[0].strip()
        if ch and ch not in out:
            out.append(ch)
    return out

def _channel_sendfax_file(channel: str) -> str:
    txt = _run_asterisk_rx(f"core show channel {channel}", timeout=5)
    for line in txt.splitlines():
        m = re.match(r"^\s*Data:\s*(.+?)\s*$", line)
        if m:
            return m.group(1).strip()
    return ""

def _tiff_page_count(path: str) -> Optional[int]:
    if not path:
        return None
    if shutil.which(TIFFINFO_BIN) is None:
        return None

    try:
        st = os.stat(path)
        cache_key = f"{path}:{st.st_mtime_ns}:{st.st_size}"
    except Exception:
        cache_key = path

    cached = _tiff_pages_cache.get(cache_key)
    if cached is not None:
        return cached[1]

    pages: Optional[int] = None
    try:
        rc, so, _ = run_cmd([TIFFINFO_BIN, path], timeout=10)
        if rc == 0:
            n = sum(1 for line in so.splitlines() if line.startswith("TIFF Directory"))
            pages = n if n > 0 else None
    except Exception as e:
        log(f"fax live: tiffinfo failed for {path}: {e}")

    _tiff_pages_cache[cache_key] = (time.time(), pages)
    if len(_tiff_pages_cache) > 100:
        for k, _ in sorted(_tiff_pages_cache.items(), key=lambda kv: kv[1][0])[:25]:
            _tiff_pages_cache.pop(k, None)
    return pages

def _parse_fax_session_ids(text: str) -> List[int]:
    out: List[int] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        low = line.lower()
        if low.startswith("current fax sessions") or low.startswith("channel ") or "fax sessions" in low:
            continue

        candidates: List[str] = []
        m = re.match(r"^(\d+)\b", line)
        if m:
            candidates.append(m.group(1))
        else:
            parts = line.split()
            candidates.extend(p for p in parts if re.match(r"^\d+$", p))

        for cand in candidates:
            try:
                sid = int(cand)
            except Exception:
                continue
            if sid not in out:
                out.append(sid)
    return out

def _parse_fax_session_details(text: str) -> Dict[str, Any]:
    raw: Dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        key = k.strip().lower().replace(" ", "_")
        raw[key] = v.strip()

    return {
        "channel": raw.get("channel", ""),
        "session": _int_or_none(raw.get("session")),
        "operation": raw.get("operation", ""),
        "state": raw.get("state", ""),
        "last_status": raw.get("last_status", ""),
        "ecm_mode": raw.get("ecm_mode", ""),
        "data_rate": _int_or_none(raw.get("data_rate")),
        "image_resolution": raw.get("image_resolution", ""),
        "page_number": _int_or_none(raw.get("page_number")),
        "file_name": raw.get("file_name", ""),
        "tx_pages": _int_or_none(raw.get("tx_pages")),
        "rx_pages": _int_or_none(raw.get("rx_pages")),
    }

def _find_job_for_tiff(tiff_path: str) -> Optional[Path]:
    if not tiff_path:
        return None
    try:
        p = Path(tiff_path)
        if p.name != "doc.tif":
            return None
        jdir = p.parent
        if jdir.parent != PROC:
            return None
        jp = jdir / "job.json"
        return jp if jp.exists() else None
    except Exception:
        return None

def _collect_asterisk_fax_live() -> Dict[str, Dict[str, Any]]:
    channels = _active_sendfax_channels()

    out: Dict[str, Dict[str, Any]] = {}
    live_by_file: Dict[str, Dict[str, Any]] = {}

    for session_id in _parse_fax_session_ids(_run_asterisk_rx("fax show sessions", timeout=5)):
        details = _parse_fax_session_details(_run_asterisk_rx(f"fax show session {session_id}", timeout=5))
        detail_file = str(details.get("file_name") or "").strip()
        if not detail_file:
            continue
        jp = _find_job_for_tiff(detail_file)
        if jp is None:
            continue

        live_by_file[detail_file] = {
            "active": True,
            "updated_at": now_iso(),
            "channel": str(details.get("channel") or ""),
            "session": details.get("session") if details.get("session") is not None else session_id,
            "operation": str(details.get("operation") or ""),
            "state": str(details.get("state") or ""),
            "last_status": str(details.get("last_status") or ""),
            "ecm_mode": str(details.get("ecm_mode") or ""),
            "data_rate": details.get("data_rate"),
            "image_resolution": str(details.get("image_resolution") or ""),
            "page_number": details.get("page_number"),
            "tx_pages": details.get("tx_pages"),
            "rx_pages": details.get("rx_pages"),
            "file_name": detail_file,
            "total_pages": _tiff_page_count(detail_file),
        }
        out[jp.parent.name] = live_by_file[detail_file]

    for channel in channels:
        tiff_path = _channel_sendfax_file(channel)
        jp = _find_job_for_tiff(tiff_path)
        if jp is None:
            continue

        jobid = jp.parent.name
        if jobid in out:
            if not out[jobid].get("channel"):
                out[jobid]["channel"] = channel
            continue

        out[jobid] = {
            "active": True,
            "updated_at": now_iso(),
            "channel": channel,
            "session": None,
            "operation": "",
            "state": "",
            "last_status": "",
            "ecm_mode": "",
            "data_rate": None,
            "image_resolution": "",
            "page_number": None,
            "tx_pages": None,
            "rx_pages": None,
            "file_name": tiff_path,
            "total_pages": _tiff_page_count(tiff_path),
        }

    return out

def step_update_asterisk_fax_live() -> None:
    global _last_fax_live_ts
    now = time.time()
    if (now - _last_fax_live_ts) < FAX_LIVE_REFRESH_SEC:
        return
    _last_fax_live_ts = now

    live_by_job = _collect_asterisk_fax_live()
    if not live_by_job:
        return

    for jdir in list_jobdirs(PROC):
        live = live_by_job.get(jdir.name)
        if not live:
            continue
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
            st = _st_norm(job)
            if st not in ("CALLING", "SENDING", "PROCESSING", "SUBMITTED", "CLAIMED"):
                continue

            root_live = job.setdefault("live", {})
            prev = root_live.get("asterisk_fax") if isinstance(root_live.get("asterisk_fax"), dict) else {}
            connected_at = str(prev.get("connected_at") or "")
            if not connected_at:
                connected_at = now_iso()
            live["connected_at"] = connected_at
            start = parse_iso_ts(connected_at)
            if start:
                live["elapsed_sec"] = int((datetime.now(timezone.utc) - start).total_seconds())

            root_live["updated_at"] = live["updated_at"]
            root_live["asterisk_fax"] = live
            job["updated_at"] = live["updated_at"]
            write_json(jp, job)
        except Exception as e:
            log(f"fax live: update failed for {jdir.name}: {e}")

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

def cancel_requested(job: Dict[str, Any]) -> bool:
    c = job.get("cancel") or {}
    return isinstance(c, dict) and bool(c.get("requested"))

def mark_cancel_handled(job: Dict[str, Any]) -> None:
    c = job.setdefault("cancel", {})
    if not isinstance(c, dict):
        c = {}
        job["cancel"] = c
    c["handled_at"] = now_iso()

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
    c.drawString(50, 40, f"Erzeugt: {now_iso()}  |  kienzlefax-worker v1.3.17")
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
    if pdf_for_archive.exists():
        try:
            merge_report_and_doc(report_pdf, pdf_for_archive, merged_pdf)
        except Exception as e:
            res = job.setdefault("result", {})
            if isinstance(res, dict):
                res["report_merge_error"] = str(e)
                res["report_merge_fallback"] = "report_only_original_copied_to_sendefehler_eingang"
            log(f"fail: qpdf merge failed for {jobdir.name}; storing report-only failure PDF: {e}")
            try:
                if merged_pdf.exists():
                    merged_pdf.unlink()
            except Exception:
                pass
            shutil.move(str(report_pdf), str(merged_pdf))
    else:
        shutil.move(str(report_pdf), str(merged_pdf))

    out_pdf = FAIL_OUT / f"{base}__{jobid}__FAILED.pdf"
    out_json = FAIL_OUT / f"{base}__{jobid}.json"
    shutil.move(str(merged_pdf), str(out_pdf))
    write_json(out_json, job)
    log(f"finalize FAILED -> {out_pdf.name}")

def finalize_unreadable_processing_job(jdir: Path, reason: str) -> bool:
    jobid = jdir.name
    chans = _find_channels_for_job(jobid)
    if chans:
        log(f"broken processing job still has active channels jobid={jobid} chans={chans}; leaving in processing")
        return False

    jp = jdir / "job.json"
    job: Dict[str, Any] = {}
    salvage_note = ""
    if jp.exists():
        job, salvage_note = read_json_best_effort(jp)

    if not isinstance(job, dict):
        job = {}

    now = now_iso()
    job["job_id"] = str(job.get("job_id") or jobid)
    job["status"] = "FAILED"
    job["updated_at"] = now
    job["end_time"] = job.get("end_time") or now
    job["finalized_at"] = job.get("finalized_at") or job["end_time"]
    job.setdefault("source", {})
    if not isinstance(job["source"], dict):
        job["source"] = {}
    job["source"]["src"] = job["source"].get("src") or "processing"
    job["source"]["filename_original"] = job["source"].get("filename_original") or f"{jobid}.pdf"
    res = job.setdefault("result", {})
    if not isinstance(res, dict):
        res = {}
        job["result"] = res
    res["reason"] = "BROKEN_PROCESSING_JOB"
    res["job_json_error"] = reason
    if salvage_note:
        res["job_json_salvage"] = salvage_note
    res["note"] = "processing-Job konnte nach Neustart nicht sauber gelesen/finalisiert werden; als Fehlerbericht abgelegt"

    try:
        finalize_failed(jdir, job)
    except Exception as e:
        log(f"broken processing finalize failed jobid={jobid}: {e}")
        try:
            write_json(jp, job)
        except Exception:
            pass
        return False

    shutil.rmtree(jdir, ignore_errors=True)
    log(f"broken processing job moved to Fehlerbericht jobid={jobid}")
    return True

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

def finalize_cancelled_queue_job(jdir: Path) -> bool:
    jp = jdir / "job.json"
    if not jp.exists():
        return False
    try:
        job = read_json(jp)
    except Exception as e:
        log(f"queue-cancel: cannot read {jdir.name}: {e}")
        return False

    if not cancel_requested(job):
        return False

    now = now_iso()
    mark_cancel_handled(job)
    job["job_id"] = str(job.get("job_id") or jdir.name)
    job["status"] = "CANCELLED"
    job["claimed_at"] = job.get("claimed_at") or now
    job["submitted_at"] = job.get("submitted_at") or now
    job["started_at"] = job.get("started_at") or now
    job["end_time"] = now
    job["finalized_at"] = now
    job["updated_at"] = job["end_time"]
    job.setdefault("result", {})
    if not isinstance(job["result"], dict):
        job["result"] = {}
    job["result"]["reason"] = job["result"].get("reason") or "cancelled"

    try:
        write_json(jp, job)
        finalize_failed(jdir, job)
    except Exception as e:
        log(f"queue-cancel: finalize failed {jdir.name}: {e}")
        try:
            write_json(jp, job)
        except Exception:
            pass
        return False

    shutil.rmtree(jdir, ignore_errors=True)
    log(f"queue-cancel: finalized CANCELLED -> {jdir.name}")
    return True

def step_queue_cancels() -> None:
    for jdir in list_jobdirs(QUEUE):
        finalize_cancelled_queue_job(jdir)

def mark_orphaned_call_for_retry(jdir: Path, job: Dict[str, Any]) -> bool:
    st = _st_norm(job)
    if st not in ("CALLING", "SENDING"):
        return False

    if job.get("end_time") or job.get("finalized_at"):
        return False

    started = parse_iso_ts(job.get("updated_at") or job.get("submitted_at") or job.get("started_at"))
    if not started:
        return False

    age = (datetime.now(timezone.utc) - started).total_seconds()
    if age < ORPHAN_CALL_TIMEOUT_SEC:
        return False

    jobid = str(job.get("job_id") or jdir.name)
    chans = _find_channels_for_job(jobid)
    if chans:
        return False

    res = job.setdefault("result", {})
    dial = str(res.get("dialstatus") or "").strip().upper()
    hcause = str(res.get("hangupcause") or "").strip()
    if dial == "ANSWER" and hcause in ("", "0", "16"):
        reason = "ORPHANED_SENT_NO_SEND_END"
        job["status"] = "FAILED"
        res["reason"] = reason
        res["faxstatus"] = res.get("faxstatus") or "UNKNOWN"
        res["orphaned_call"] = True
        res["orphaned_call_age_sec"] = int(age)
        res["assumed_success"] = False
        res["note"] = "send_start und DIALSTATUS=ANSWER wurden erreicht, aber send_end fehlt; als Fehlerbericht abgelegt, kein automatischer Retry"

        a = job.setdefault("attempt", {})
        a["ended_at"] = now_iso()
        a["last_reason"] = reason

        job["end_time"] = now_iso()
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]
        job["updated_at"] = job["end_time"]
        write_json(jdir / "job.json", job)
        log(f"orphaned sending job moved to failed flow jobid={jobid} dial={dial or 'n/a'} hcause={hcause or 'n/a'} age={int(age)}s")
        return True

    if st == "SENDING" or dial == "ANSWER":
        reason = "UNKNOWN_SENT_NO_SEND_END"
        job["status"] = "FAILED"
        res["reason"] = reason
        res["orphaned_call"] = True
        res["orphaned_call_age_sec"] = int(age)
        res["note"] = "send_start wurde erreicht, aber send_end fehlt; kein Retry, um Doppelversand zu vermeiden"

        a = job.setdefault("attempt", {})
        a["ended_at"] = now_iso()
        a["last_reason"] = reason

        job["end_time"] = now_iso()
        job["finalized_at"] = job.get("finalized_at") or job["end_time"]
        job["updated_at"] = job["end_time"]
        write_json(jdir / "job.json", job)
        log(f"orphaned sending job finalized without retry jobid={jobid} dial={dial or 'n/a'} hcause={hcause or 'n/a'} age={int(age)}s")
        return True

    if dial in ("BUSY", "NOANSWER", "CONGESTION", "CHANUNAVAIL"):
        reason = dial
        delay = 20 if dial in ("CONGESTION", "CHANUNAVAIL") else 90
        max_attempts = 30 if dial in ("CONGESTION", "CHANUNAVAIL") else (15 if dial == "BUSY" else 3)
    else:
        reason = "CHANUNAVAIL"
        delay = 20
        max_attempts = 30

    job["status"] = "RETRY"
    res["reason"] = res.get("reason") or f"{reason}_NO_SEND_END"
    res["orphaned_call"] = True
    res["orphaned_call_age_sec"] = int(age)

    r = job.setdefault("retry", {})
    r["max"] = max_attempts
    r["last_reason"] = reason
    r["suggested_delay_sec"] = delay
    r["next_try_at"] = (datetime.now(timezone.utc) + timedelta(seconds=delay)).replace(microsecond=0).isoformat()

    a = job.setdefault("attempt", {})
    a["ended_at"] = now_iso()
    a["last_reason"] = reason
    a["max"] = max_attempts

    job["updated_at"] = now_iso()
    write_json(jdir / "job.json", job)
    log(f"orphaned call recovered jobid={jobid} status={st} dial={dial or 'n/a'} reason={reason} age={int(age)}s")
    return True

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
                log(f"cancel: no channels found jobid={jobid}; finalizing CANCELLED")
                job["status"] = "CANCELLED"
                job.setdefault("result", {})["reason"] = "cancelled"
                job.setdefault("cancel", {})
                job["cancel"]["handled_at"] = now_iso()
                job["end_time"] = now_iso()
                job["finalized_at"] = job.get("finalized_at") or job["end_time"]
                job["updated_at"] = job["end_time"]
                write_json(jp, job)
                continue

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
            if finalize_unreadable_processing_job(jdir, "job.json missing"):
                _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue
        try:
            job = read_json(jp)
        except Exception as e:
            if finalize_unreadable_processing_job(jdir, f"job.json unreadable: {e}"):
                _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

        st = _st_norm(job)

        if mark_orphaned_call_for_retry(jdir, job):
            _next_submit_ts = time.time() + POST_CALL_COOLDOWN_SEC
            continue

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

        if st in ("FAILED", "CANCELLED"):
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
    log("started (v1.3.17)")
    try:
        while True:
            step_update_asterisk_fax_live()
            step_queue_cancels()
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

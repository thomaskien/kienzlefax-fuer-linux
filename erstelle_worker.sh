sudo bash -euxo pipefail <<'EOF'
WORKER="/usr/local/bin/kienzlefax-worker.py"

cat > "$WORKER" <<'PY'
#!/usr/bin/env python3
# kienzlefax-worker.py  (B: submit + finalize via doneq/q<JID> + PDF-Report+Merge)
# Stand: 2026-02-13
#
# Änderung (nach Absprache):
# - Direkt vor sendfax wird optional ein Header ergänzt via /usr/local/bin/pdf_with_header.sh
# - Für sendfax UND für Report-Merge wird dann die Header-Version verwendet.
# - Unverändertes Original bleibt (source.pdf) für sendefehler/eingang/.

import json
import os
import re
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Tuple, Dict, Any, List

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas
from reportlab.lib.units import mm

BASE = Path("/srv/kienzlefax")
QUEUE = BASE / "queue"
PROC  = BASE / "processing"

ARCH  = BASE / "sendeberichte"
FAIL_IN  = BASE / "sendefehler" / "eingang"
FAIL_REP = BASE / "sendefehler" / "berichte"

DONEQ = Path("/var/spool/hylafax/doneq")

MAX_INFLIGHT = 2
POLL_SEC = 2

SENDFAX_TIMEOUT = 60

JID_RE = re.compile(r"\brequest id is\s+(\d+)\b", re.IGNORECASE)

HEADER_SCRIPT = Path("/usr/local/bin/pdf_with_header.sh")  # <-- NEU

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")

def log(msg: str) -> None:
    print(f"[{now_iso()}] {msg}", flush=True)

def read_json(p: Path) -> Dict[str, Any]:
    return json.loads(p.read_text(encoding="utf-8"))

def write_json_atomic(p: Path, obj: Dict[str, Any]) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, p)

def list_jobdirs(d: Path) -> List[Path]:
    if not d.is_dir():
        return []
    out = [p for p in d.iterdir() if p.is_dir()]
    out.sort(key=lambda x: x.name)
    return out

def claim_next_job() -> Optional[Path]:
    for j in list_jobdirs(QUEUE):
        target = PROC / j.name
        try:
            j.rename(target)
            log(f"claimed {j.name}")
            return target
        except PermissionError as e:
            log(f"claim rename denied for {j.name}: {e}")
        except Exception as e:
            log(f"claim rename failed for {j.name}: {e}")
    return None

def run_cmd(cmd: List[str], timeout: int) -> Tuple[int, str, str]:
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()

def sendfax_submit(number: str, pdf: Path) -> Tuple[Optional[int], str, str, int]:
    cmd = ["sendfax", "-n", "-d", number, str(pdf)]
    try:
        rc, out, err = run_cmd(cmd, timeout=SENDFAX_TIMEOUT)
    except Exception as e:
        return None, "", str(e), 999
    m = JID_RE.search(out) or JID_RE.search(err)
    jid = int(m.group(1)) if m else None
    return jid, out, err, rc

def parse_doneq_qfile(jid: int) -> Optional[Dict[str, str]]:
    qf = DONEQ / f"q{jid}"
    if not qf.is_file():
        return None
    data: Dict[str, str] = {}
    for ln in qf.read_text(errors="replace").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        if ":" not in ln:
            continue
        k, v = ln.split(":", 1)
        data[k.strip()] = v.strip()
    return data

def safe_basename(s: str) -> str:
    s = (s or "").strip()
    s = re.sub(r"\.pdf$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s[:80] if s else "fax"

def unique_dest(path: Path) -> Path:
    if not path.exists():
        return path
    stem = path.stem
    suf = path.suffix
    for i in range(1, 200):
        cand = path.with_name(f"{stem}__{i}{suf}")
        if not cand.exists():
            return cand
    return path.with_name(f"{stem}__{int(time.time())}{suf}")

def make_report_pdf(report_path: Path, title: str, lines: List[Tuple[str, str]], status_ok: bool) -> None:
    c = canvas.Canvas(str(report_path), pagesize=A4)
    w, h = A4

    c.setFont("Helvetica-Bold", 18)
    c.drawString(20*mm, h - 20*mm, title)

    c.setFont("Helvetica-Bold", 14)
    badge = "ERFOLGREICH" if status_ok else "FEHLGESCHLAGEN"
    c.drawString(20*mm, h - 32*mm, f"Status: {badge}")

    y = h - 48*mm
    c.setFont("Helvetica-Bold", 10)
    for k, v in lines:
        if y < 20*mm:
            break
        c.drawString(20*mm, y, f"{k}:")
        c.setFont("Helvetica", 10)
        txt = (v or "").strip()
        max_chars = 95
        chunks = [txt[i:i+max_chars] for i in range(0, len(txt), max_chars)] or [""]
        c.drawString(55*mm, y, chunks[0])
        y -= 6*mm
        for ch in chunks[1:3]:
            if y < 20*mm:
                break
            c.drawString(55*mm, y, ch)
            y -= 6*mm
        c.setFont("Helvetica-Bold", 10)

    c.setFont("Helvetica", 8)
    c.drawRightString(w - 15*mm, 12*mm, f"kienzlefax · erzeugt {now_iso()}")
    c.showPage()
    c.save()

def qpdf_merge(report_pdf: Path, doc_pdf: Path, out_pdf: Path) -> None:
    out_pdf.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["qpdf", "--empty", "--pages", str(report_pdf), str(doc_pdf), "--", str(out_pdf)]
    rc, out, err = run_cmd(cmd, timeout=60)
    if rc != 0:
        raise RuntimeError(f"qpdf merge failed rc={rc} err={err[:200]} out={out[:200]}")

# =========================
# NEU: Header-Generator
# =========================
def add_header(pdf: Path) -> Path:
    out = pdf.with_name(pdf.stem + "_hdr.pdf")
    subprocess.run(
        [str(HEADER_SCRIPT), str(pdf), str(out)],
        check=True,
    )
    return out

def finalize_job(jobdir: Path, job: Dict[str, Any], final_status: str, reason: str, doneq: Dict[str, str]) -> None:
    jobid = job.get("job_id", jobdir.name)

    src_fn = ((job.get("source") or {}).get("filename_original")) or "document.pdf"
    src_base = safe_basename(src_fn)

    recipient = job.get("recipient") or {}
    r_name = str(recipient.get("name") or "")
    r_num  = str(recipient.get("number") or "")

    # PDFs im Jobdir
    doc_pdf = jobdir / "doc.pdf"

    # NEU: falls vorhanden, Header-Version für Merge/Archiv verwenden
    rendered_name = str(job.get("rendered_pdf") or "").strip()
    rendered_pdf = (jobdir / rendered_name) if rendered_name else None
    pdf_for_merge = rendered_pdf if (rendered_pdf and rendered_pdf.exists()) else doc_pdf

    # Original unverändert (von PHP ins Jobdir verschoben)
    source_pdf = jobdir / "source.pdf"
    if not source_pdf.exists():
        source_pdf = doc_pdf

    # Doneq-Auswertung
    sc_raw = (doneq.get("statuscode") or "").strip()
    try:
        statuscode = int(sc_raw) if sc_raw != "" else None
    except Exception:
        statuscode = None

    npages = int((doneq.get("npages") or "0") or "0")
    totpages = int((doneq.get("totpages") or "0") or "0")

    signalrate = doneq.get("signalrate", "").strip()
    csi = doneq.get("csi", "").strip()
    commid = doneq.get("commid", "").strip()

    pages_str = f"{npages}/{totpages}" if totpages else (str(npages) if npages else "")
    job.setdefault("result", {})
    job["result"].update({
        "reason": reason,
        "statuscode": statuscode,
        "status_text": (doneq.get("status") or "").strip(),
        "npages": npages,
        "totpages": totpages,
        "pages": pages_str,
        "signalrate": signalrate,
        "csi": csi,
        "commid": commid,
        "document_name": src_fn,
    })

    job["status"] = final_status
    job["finalized_at"] = now_iso()
    job["end_time"] = job["finalized_at"]

    # Report erstellen
    status_ok = (final_status == "OK")
    report_pdf = jobdir / "report.pdf"

    title = "Fax-Sendebericht"
    lines = [
        ("Job", jobid),
        ("Ergebnis", "Senden erfolgreich" if status_ok else "Senden fehlgeschlagen"),
        ("Empfänger", r_name),
        ("Faxnummer", r_num),
        ("Dokument", src_fn),
        ("Seiten", pages_str or str(npages) or "—"),
        ("Geschwindigkeit", signalrate or "—"),
        ("CSI", csi or "—"),
        ("HylaFAX JID", str((job.get("hylafax") or {}).get("jid") or "")),
        ("CommID", commid or "—"),
        ("Start (UTC)", str(job.get("started_at") or job.get("submitted_at") or "")),
        ("Ende (UTC)", str(job.get("end_time") or "")),
        ("Hinweis", "Dauer wird im Web-UI aus Start/Ende berechnet."),
    ]
    make_report_pdf(report_pdf, title, lines, status_ok=status_ok)

    # Merged PDF erzeugen: Report + (Header-Dokument oder doc.pdf)
    if not pdf_for_merge.exists():
        raise RuntimeError("PDF for merge missing in jobdir")

    if status_ok:
        ARCH.mkdir(parents=True, exist_ok=True)
        out_pdf = ARCH / f"{src_base}__{jobid}__OK.pdf"
        out_json = ARCH / f"{src_base}__{jobid}.json"
    else:
        FAIL_REP.mkdir(parents=True, exist_ok=True)
        out_pdf = FAIL_REP / f"{src_base}__{jobid}__FAILED.pdf"
        out_json = FAIL_REP / f"{src_base}__{jobid}.json"

    tmp_pdf = out_pdf.with_suffix(out_pdf.suffix + ".tmp")
    qpdf_merge(report_pdf, pdf_for_merge, tmp_pdf)
    os.replace(tmp_pdf, out_pdf)

    write_json_atomic(out_json, job)

    # Bei FAIL: unverändertes Original als Drop-in ablegen (source.pdf)
    if not status_ok:
        FAIL_IN.mkdir(parents=True, exist_ok=True)
        dst_orig = FAIL_IN / Path(src_fn).name
        dst_orig = unique_dest(dst_orig)
        try:
            shutil.copy2(source_pdf, dst_orig)
        except Exception as e:
            log(f"copy to sendefehler/eingang failed: {e}")

    log(f"final {final_status} -> {out_pdf.name} + {out_json.name}")

    shutil.rmtree(jobdir, ignore_errors=True)

def submitter_step() -> None:
    inflight = 0
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue
        try:
            job = read_json(jp)
        except Exception:
            continue
        if (job.get("status") or "").lower() == "submitted":
            inflight += 1
    if inflight >= MAX_INFLIGHT:
        return

    jdir = claim_next_job()
    if not jdir:
        return

    jp = jdir / "job.json"
    dp = jdir / "doc.pdf"
    if not jp.exists() or not dp.exists():
        log(f"jobdir incomplete: {jdir}")
        shutil.rmtree(jdir, ignore_errors=True)
        return

    job = read_json(jp)
    job["claimed_at"] = now_iso()
    job["status"] = "claimed"
    write_json_atomic(jp, job)

    number = ((job.get("recipient") or {}).get("number") or "").strip()
    if not number:
        job["submitted_at"] = now_iso()
        job["started_at"] = job["submitted_at"]
        job["hylafax"] = {"jid": None}
        finalize_job(jdir, job, "FAILED", "missing recipient number", doneq={"statuscode": "999", "status": "missing recipient number"})
        return

    # =========================
    # NEU: Header vor sendfax
    # =========================
    pdf_to_send = dp
    try:
        if HEADER_SCRIPT.exists():
            hdr = add_header(dp)
            if hdr.exists() and hdr.stat().st_size > 0:
                pdf_to_send = hdr
                job["rendered_pdf"] = hdr.name  # damit finalize_job den gleichen nimmt
            else:
                log("header: output missing/empty, sending without header")
        else:
            log("header: script missing, sending without header")
    except Exception as e:
        log(f"header generation failed, sending without header: {e}")

    jid, out, err, rc = sendfax_submit(number, pdf_to_send)

    job["submitted_at"] = now_iso()
    job["started_at"] = job["submitted_at"]
    job.setdefault("hylafax", {})
    job["hylafax"].update({
        "jid": jid,
        "sendfax_rc": rc,
        "sendfax_out": out[:800],
        "sendfax_err": err[:800],
    })

    if jid is None or rc != 0:
        reason = f"sendfax failed rc={rc}"
        if err:
            reason += f" ({err[:120]})"
        finalize_job(jdir, job, "FAILED", reason, doneq={"statuscode": str(rc), "status": reason})
        return

    job["status"] = "submitted"
    write_json_atomic(jp, job)
    log(f"submitted {jdir.name} -> HylaFAX JID={jid}")

def finalizer_step() -> None:
    for jdir in list_jobdirs(PROC):
        jp = jdir / "job.json"
        if not jp.exists():
            continue

        try:
            job = read_json(jp)
        except Exception as e:
            log(f"bad job.json {jdir.name}: {e}")
            continue

        if (job.get("status") or "").lower() != "submitted":
            continue

        jid = ((job.get("hylafax") or {}).get("jid"))
        if not isinstance(jid, int):
            continue

        q = parse_doneq_qfile(jid)
        if q is None:
            continue

        sc_raw = (q.get("statuscode") or "").strip()
        try:
            statuscode = int(sc_raw) if sc_raw != "" else None
        except Exception:
            statuscode = None

        final_status = "OK" if statuscode == 0 else "FAILED"
        status_text = (q.get("status") or "").strip()
        if final_status == "OK":
            reason = "OK"
        else:
            reason = status_text if status_text else (f"statuscode={statuscode}" if statuscode is not None else "FAILED")

        job["finalizing_at"] = now_iso()
        write_json_atomic(jp, job)

        try:
            finalize_job(jdir, job, final_status, reason, q)
        except Exception as e:
            job = read_json(jp)
            job.setdefault("result", {})
            job["result"]["worker_error"] = str(e)
            write_json_atomic(jp, job)
            log(f"finalize error for {jdir.name}: {e}")

def main() -> None:
    log("kienzlefax-worker started (B-mode + PDF report/merge + optional header)")
    while True:
        try:
            submitter_step()
            finalizer_step()
        except Exception as e:
            log(f"worker loop error: {e}")
        time.sleep(POLL_SEC)

if __name__ == "__main__":
    main()
PY

chmod 0755 "$WORKER"
systemctl restart kienzlefax-worker.service

echo
echo "==> Live-Log (Ctrl+C beendet):"
journalctl -u kienzlefax-worker -f
EOF


sudo bash -euxo pipefail <<'EOF'
# 1) Gruppen anlegen/ergänzen
getent group kienzlefax >/dev/null || groupadd --system kienzlefax
id faxworker >/dev/null 2>&1 || useradd --system --home /var/lib/faxworker --create-home --shell /usr/sbin/nologin faxworker

usermod -aG kienzlefax faxworker

# HylaFAX-Spool ist auf Ubuntu sehr oft uucp: -> faxworker dazu
getent group uucp >/dev/null && usermod -aG uucp faxworker || true
getent group fax >/dev/null && usermod -aG fax faxworker || true

# optional, je nach späterem Modem/Gateway:
getent group dialout >/dev/null && usermod -aG dialout faxworker || true

# 2) Verzeichnisse kienzlefax absichern (wie gehabt)
apt-get update
apt-get install -y acl python3 python3-reportlab qpdf hylafax-client

mkdir -p /srv/kienzlefax/{staging,queue,processing,sendeberichte}
mkdir -p /srv/kienzlefax/sendefehler/{eingang,berichte}

chgrp -R kienzlefax /srv/kienzlefax
find /srv/kienzlefax -type d -exec chmod 2775 {} \;
find /srv/kienzlefax -type f -exec chmod 0664 {} \;

setfacl -R -m g:kienzlefax:rwx /srv/kienzlefax
setfacl -R -d -m g:kienzlefax:rwx /srv/kienzlefax
setfacl -R -d -m u::rwx /srv/kienzlefax
setfacl -R -d -m o::rx  /srv/kienzlefax

# 3) HylaFAX-Spool-Rechte prüfen (nur Anzeige)
echo "== HylaFAX spool perms =="
ls -ld /var/spool/hylafax /var/spool/hylafax/{sendq,docq,doneq} 2>/dev/null || true

# 4) systemd Service korrigieren: HylaFAX spool MUSS schreibbar sein
cat > /etc/systemd/system/kienzlefax-worker.service <<'UNIT'
[Unit]
Description=kienzlefax worker (HylaFAX sendfax consumer)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=faxworker
Group=kienzlefax
WorkingDirectory=/srv/kienzlefax

Environment=PYTHONUNBUFFERED=1
Environment=TZ=UTC

ExecStart=/usr/bin/python3 /usr/local/bin/kienzlefax-worker.py

Restart=always
RestartSec=2
StartLimitIntervalSec=30
StartLimitBurst=50

# Hardening (nicht zu hart):
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

# Wichtig: Worker schreibt in /srv/kienzlefax UND sendfax schreibt in HylaFAX-Spool:
ReadWritePaths=/srv/kienzlefax /var/spool/hylafax

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable kienzlefax-worker.service
systemctl restart kienzlefax-worker.service || true

EOF



sudo bash -euxo pipefail <<'EOF'
# 1) Gruppen anlegen/ergänzen
getent group kienzlefax >/dev/null || groupadd --system kienzlefax
id faxworker >/dev/null 2>&1 || useradd --system --home /var/lib/faxworker --create-home --shell /usr/sbin/nologin faxworker

usermod -aG kienzlefax faxworker

# HylaFAX-Spool ist auf Ubuntu sehr oft uucp: -> faxworker dazu
getent group uucp >/dev/null && usermod -aG uucp faxworker || true
getent group fax >/dev/null && usermod -aG fax faxworker || true

# optional, je nach späterem Modem/Gateway:
getent group dialout >/dev/null && usermod -aG dialout faxworker || true

# 2) Verzeichnisse kienzlefax absichern (wie gehabt)
apt-get update
apt-get install -y acl python3 python3-reportlab qpdf hylafax-client

mkdir -p /srv/kienzlefax/{staging,queue,processing,sendeberichte}
mkdir -p /srv/kienzlefax/sendefehler/{eingang,berichte}

chgrp -R kienzlefax /srv/kienzlefax
find /srv/kienzlefax -type d -exec chmod 2775 {} \;
find /srv/kienzlefax -type f -exec chmod 0664 {} \;

setfacl -R -m g:kienzlefax:rwx /srv/kienzlefax
setfacl -R -d -m g:kienzlefax:rwx /srv/kienzlefax
setfacl -R -d -m u::rwx /srv/kienzlefax
setfacl -R -d -m o::rx  /srv/kienzlefax

# 3) HylaFAX-Spool-Rechte prüfen (nur Anzeige)
echo "== HylaFAX spool perms =="
ls -ld /var/spool/hylafax /var/spool/hylafax/{sendq,docq,doneq} 2>/dev/null || true

# 4) systemd Service korrigieren: HylaFAX spool MUSS schreibbar sein
cat > /etc/systemd/system/kienzlefax-worker.service <<'UNIT'
[Unit]
Description=kienzlefax worker (HylaFAX sendfax consumer)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=faxworker
Group=kienzlefax
WorkingDirectory=/srv/kienzlefax

Environment=PYTHONUNBUFFERED=1
Environment=TZ=UTC

ExecStart=/usr/bin/python3 /usr/local/bin/kienzlefax-worker.py

Restart=always
RestartSec=2
StartLimitIntervalSec=30
StartLimitBurst=50

# Hardening (nicht zu hart):
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

# Wichtig: Worker schreibt in /srv/kienzlefax UND sendfax schreibt in HylaFAX-Spool:
ReadWritePaths=/srv/kienzlefax /var/spool/hylafax

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable kienzlefax-worker.service
systemctl restart kienzlefax-worker.service || true

echo
echo "== Status =="
systemctl status kienzlefax-worker.service --no-pager || true
EOF







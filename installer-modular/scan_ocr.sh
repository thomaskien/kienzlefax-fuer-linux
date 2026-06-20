#!/usr/bin/env bash
set -euo pipefail

VERSION="1.3"

log(){ echo "[$(date -Is)] scan-ocr-install: $*"; }

backup_file_ts() {
  local f="$1"
  local stamp=".old.scan-ocr.$(date +%Y%m%d-%H%M%S)"
  if [ -e "$f" ]; then
    cp -a "$f" "${f}${stamp}" 2>/dev/null || true
    log "backup: $f -> ${f}${stamp}"
  fi
}

SCAN_BASE="/srv/scan"
SCAN_IN="${SCAN_BASE}/eingang"
SCAN_OUT="${SCAN_BASE}/ocr"
SCAN_ARCH="${SCAN_BASE}/archiv"
SCAN_ERR="${SCAN_BASE}/fehler"
SCAN_WORK="/var/tmp/scan-ocr"
SCAN_FAX_IN="${SCAN_BASE}/fax-eingang"
SCAN_FAX_ARCH="${SCAN_BASE}/fax-archiv"
SCAN_FAX_ERR="${SCAN_BASE}/fax-fehler"
SCAN_FAX_WORK="/var/tmp/scan-ocr-fax"

log "installiere Scan-OCR Pipeline v${VERSION}"

if ! getent group scanocr >/dev/null 2>&1; then
  groupadd --system scanocr
fi
if ! id scanocr >/dev/null 2>&1; then
  useradd --system --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin --gid scanocr scanocr
fi

install -d -o scanocr -g scanocr -m 0777 \
  "$SCAN_IN" "$SCAN_OUT" "$SCAN_ARCH" "$SCAN_ERR" "$SCAN_WORK" \
  "$SCAN_FAX_IN" "$SCAN_FAX_ARCH" "$SCAN_FAX_ERR" "$SCAN_FAX_WORK"
install -d -m 0777 /var/spool/asterisk/fax
chmod 0777 \
  "$SCAN_BASE" "$SCAN_IN" "$SCAN_OUT" "$SCAN_ARCH" "$SCAN_ERR" "$SCAN_WORK" \
  "$SCAN_FAX_IN" "$SCAN_FAX_ARCH" "$SCAN_FAX_ERR" "$SCAN_FAX_WORK" \
  /var/spool/asterisk/fax || true
chown -R scanocr:scanocr "$SCAN_BASE" "$SCAN_WORK" || true

EMBED="/usr/local/bin/embed-json-in-pdf.py"
backup_file_ts "$EMBED"
cat >"$EMBED" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
embed-json-in-pdf.py - embeds scan-ocr.json into a PDF.
Version: 1.0
"""

import shutil
import sys
from pathlib import Path

from pikepdf import AttachedFileSpec, Name, Pdf


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: embed-json-in-pdf.py input.pdf metadata.json output.pdf", file=sys.stderr)
        return 2

    in_pdf = Path(sys.argv[1])
    meta_json = Path(sys.argv[2])
    out_pdf = Path(sys.argv[3])

    if not in_pdf.is_file():
        print(f"ERROR: input PDF not found: {in_pdf}", file=sys.stderr)
        return 2
    if not meta_json.is_file():
        print(f"ERROR: metadata JSON not found: {meta_json}", file=sys.stderr)
        return 2

    out_pdf.parent.mkdir(parents=True, exist_ok=True)

    try:
        with Pdf.open(str(in_pdf)) as pdf:
            data = meta_json.read_bytes()
            pdf.attachments["scan-ocr.json"] = AttachedFileSpec(
                pdf,
                data,
                mime_type="application/json",
                description="scan-ocr metadata",
            )
            try:
                pdf.Root.PageMode = Name.UseAttachments
            except Exception:
                try:
                    pdf.root.PageMode = Name.UseAttachments
                except Exception:
                    pass
            pdf.save(str(out_pdf))
    except Exception as exc:
        print(f"ERROR: could not embed JSON metadata: {exc}", file=sys.stderr)
        try:
            shutil.copy2(str(in_pdf), str(out_pdf))
        except Exception as copy_exc:
            print(f"ERROR: fallback copy failed: {copy_exc}", file=sys.stderr)
            return 1
        return 3

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod 0755 "$EMBED"
chown root:root "$EMBED"
python3 -m py_compile "$EMBED"

WATCH="/usr/local/bin/scan-ocr-watch.sh"
backup_file_ts "$WATCH"
cat >"$WATCH" <<'WATCH'
#!/usr/bin/env bash
set -euo pipefail

VERSION="1.3"
IN_DIR="${SCAN_OCR_IN_DIR:-/srv/scan/eingang}"
OUT_DIR="${SCAN_OCR_OUT_DIR:-/srv/scan/ocr}"
ARCH_DIR="${SCAN_OCR_ARCH_DIR:-/srv/scan/archiv}"
ERR_DIR="${SCAN_OCR_ERR_DIR:-/srv/scan/fehler}"
WORK_BASE="${SCAN_OCR_WORK_DIR:-/var/tmp/scan-ocr}"
OUTPUT_SUFFIX="${SCAN_OCR_OUTPUT_SUFFIX-_OCR}"
LANGS="${SCAN_OCR_LANG:-deu+eng}"
JOBS="${SCAN_OCR_JOBS:-2}"
STABLE_WAIT_SEC="${SCAN_OCR_STABLE_WAIT_SEC:-2}"
RESCAN_SEC="${SCAN_OCR_RESCAN_SEC:-30}"
EMBED_JSON="${SCAN_OCR_EMBED_JSON:-/usr/local/bin/embed-json-in-pdf.py}"

log(){ echo "[$(date -Is)] scan-ocr: $*"; }

safe_mkdirs(){
  mkdir -p "$IN_DIR" "$ARCH_DIR" "$ERR_DIR" "$WORK_BASE"
  mkdir -p "$OUT_DIR" 2>/dev/null || true
  chmod 0777 "$IN_DIR" "$ARCH_DIR" "$ERR_DIR" "$WORK_BASE" || true
  chmod 0777 "$OUT_DIR" 2>/dev/null || true
  if [[ ! -w "$OUT_DIR" ]]; then
    log "WARN: Ausgabeverzeichnis ist nicht schreibbar: $OUT_DIR"
  fi
}

lower_ext(){
  local name="$1"
  if [[ "$name" != *.* ]]; then
    printf '%s\n' ""
    return 0
  fi
  printf '%s\n' "${name##*.}" | tr '[:upper:]' '[:lower:]'
}

stem_of(){
  local name="$1"
  if [[ "$name" == *.* ]]; then
    printf '%s\n' "${name%.*}"
  else
    printf '%s\n' "$name"
  fi
}

unique_path(){
  local dir="$1"
  local name="$2"
  local stem ext candidate counter stamp
  stem="$(stem_of "$name")"
  if [[ "$name" == *.* ]]; then
    ext=".${name##*.}"
  else
    ext=""
  fi
  candidate="${dir}/${stem}${ext}"
  if [[ ! -e "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  counter=1
  while true; do
    candidate="${dir}/${stem}__${stamp}_${counter}${ext}"
    if [[ ! -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    counter=$((counter + 1))
  done
}

stable_file(){
  local f="$1"
  local last cur i
  [[ -f "$f" ]] || return 1
  last="$(stat -c '%s' -- "$f" 2>/dev/null)" || return 1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep "$STABLE_WAIT_SEC"
    [[ -f "$f" ]] || return 1
    cur="$(stat -c '%s' -- "$f" 2>/dev/null)" || return 1
    if [[ "$cur" == "$last" ]]; then
      return 0
    fi
    last="$cur"
  done
  return 1
}

write_metadata(){
  local path="$1" status="$2" input_name="$3" output_name="$4" attempted="$5" success="$6" fallback="$7" err="$8"
  META_PATH="$path" \
  SCAN_STATUS="$status" \
  SCAN_INPUT="$input_name" \
  SCAN_OUTPUT="$output_name" \
  SCAN_ATTEMPTED="$attempted" \
  SCAN_SUCCESS="$success" \
  SCAN_FALLBACK="$fallback" \
  SCAN_ERROR="$err" \
  SCAN_VERSION="$VERSION" \
  SCAN_LANG="$LANGS" \
  python3 - <<'PY'
import json
import os
from datetime import datetime
from pathlib import Path

def as_bool(name):
    return os.environ.get(name, "").lower() == "true"

error = os.environ.get("SCAN_ERROR", "")
data = {
    "processor": "scan-ocr",
    "version": os.environ["SCAN_VERSION"],
    "status": os.environ["SCAN_STATUS"],
    "ocr_engine": "ocrmypdf/tesseract",
    "language": os.environ["SCAN_LANG"],
    "input_filename": os.environ["SCAN_INPUT"],
    "output_filename": os.environ["SCAN_OUTPUT"],
    "processed_at": datetime.now().astimezone().replace(microsecond=0).isoformat(),
    "ocr_attempted": as_bool("SCAN_ATTEMPTED"),
    "ocr_success": as_bool("SCAN_SUCCESS"),
    "fallback_used": as_bool("SCAN_FALLBACK"),
    "error": error if error else None,
}
Path(os.environ["META_PATH"]).write_text(
    json.dumps(data, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
}

move_to_error(){
  local src="$1" reason="$2"
  local base dest
  base="$(basename -- "$src")"
  dest="$(unique_path "$ERR_DIR" "$base")"
  mv -- "$src" "$dest"
  chmod 0666 "$dest" || true
  log "FEHLER: ${base} -> ${dest} (${reason})"
}

ocr_mode_args(){
  if ocrmypdf --help 2>/dev/null | grep -q -- '--mode'; then
    printf '%s\n' "--mode" "skip"
  else
    printf '%s\n' "--skip-text"
  fi
}

process_file(){
  local src="$1"
  [[ -f "$src" ]] || return 0

  local name ext work orig normalized ocr_pdf ocr_log out_name out_path meta final_src status
  local ocr_success fallback err archive_path stem

  name="$(basename -- "$src")"
  [[ "$name" == .* ]] && return 0

  if ! stable_file "$src"; then
    log "Datei noch nicht stabil oder verschwunden: $name"
    return 0
  fi

  work="$(mktemp -d -p "$WORK_BASE" "job.XXXXXX")"
  orig="$work/$name"
  if ! mv -- "$src" "$orig"; then
    rm -rf "$work"
    log "konnte Datei nicht in Arbeitsverzeichnis verschieben: $name"
    return 0
  fi

  normalized="$work/input.pdf"
  ext="$(lower_ext "$name")"
  case "$ext" in
    pdf)
      if ! cp -p -- "$orig" "$normalized"; then
        move_to_error "$orig" "PDF konnte nicht gelesen/kopiert werden"
        rm -rf "$work"
        return 0
      fi
      ;;
    jpg|jpeg|png|tif|tiff)
      if ! img2pdf --output "$normalized" "$orig" >"$work/img2pdf.log" 2>&1; then
        err="$(tail -c 2000 "$work/img2pdf.log" 2>/dev/null | tr '\n' ' ')"
        move_to_error "$orig" "img2pdf fehlgeschlagen: ${err}"
        rm -rf "$work"
        return 0
      fi
      ;;
    *)
      move_to_error "$orig" "nicht unterstuetzter Dateityp"
      rm -rf "$work"
      return 0
      ;;
  esac

  stem="$(stem_of "$name")"
  [[ -n "$stem" ]] || stem="scan"
  out_name="${stem}${OUTPUT_SUFFIX}.pdf"
  out_path="$(unique_path "$OUT_DIR" "$out_name")"
  out_name="$(basename -- "$out_path")"
  ocr_pdf="$work/ocr.pdf"
  ocr_log="$work/ocrmypdf.log"
  meta="$work/scan-ocr.json"
  status="ocr_failed_original_passed_through"
  ocr_success="false"
  fallback="true"
  err=""
  final_src="$normalized"

  mapfile -t mode_args < <(ocr_mode_args)
  if ocrmypdf \
      "${mode_args[@]}" \
      -l "$LANGS" \
      --tesseract-oem 1 \
      --rotate-pages \
      --deskew \
      --clean \
      --oversample 300 \
      --output-type pdfa-3 \
      --optimize 1 \
      --tesseract-timeout 300 \
      --jobs "$JOBS" \
      "$normalized" "$ocr_pdf" >"$ocr_log" 2>&1 && [[ -s "$ocr_pdf" ]]; then
    status="ocr_ok"
    ocr_success="true"
    fallback="false"
    final_src="$ocr_pdf"
  else
    rc=$?
    err="ocrmypdf failed with exit code ${rc}: $(tail -c 4000 "$ocr_log" 2>/dev/null | tr '\n' ' ')"
    log "OCR fehlgeschlagen, Fallback wird ausgegeben: $name"
  fi

  write_metadata "$meta" "$status" "$name" "$out_name" "true" "$ocr_success" "$fallback" "$err"

  if "$EMBED_JSON" "$final_src" "$meta" "$out_path" >"$work/embed.log" 2>&1; then
    :
  else
    rc=$?
    log "JSON-Einbettung fehlgeschlagen rc=${rc}, PDF wird ohne eingebettete Metadaten ausgegeben: $name"
    cp -f -- "$final_src" "$out_path"
  fi
  chmod 0666 "$out_path" || true

  archive_path="$(unique_path "$ARCH_DIR" "$name")"
  mv -- "$orig" "$archive_path"
  chmod 0666 "$archive_path" || true

  log "OK: $name -> $out_path (status=${status})"
  rm -rf "$work"
}

scan_once(){
  safe_mkdirs
  while IFS= read -r -d '' f; do
    process_file "$f"
  done < <(find "$IN_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
}

main(){
  safe_mkdirs
  log "started v${VERSION}: input=${IN_DIR} output=${OUT_DIR}"
  while true; do
    scan_once
    if command -v inotifywait >/dev/null 2>&1; then
      inotifywait -qq -t "$RESCAN_SEC" -e close_write,moved_to "$IN_DIR" >/dev/null 2>&1 || true
    else
      sleep "$RESCAN_SEC"
    fi
  done
}

main "$@"
WATCH
chmod 0755 "$WATCH"
chown root:root "$WATCH"
bash -n "$WATCH"

UNIT="/etc/systemd/system/scan-ocr.service"
backup_file_ts "$UNIT"
cat >"$UNIT" <<'UNIT'
[Unit]
Description=scan-ocr watcher
After=network-online.target smbd.service
Wants=network-online.target

[Service]
Type=simple
User=scanocr
Group=scanocr
ExecStart=/usr/local/bin/scan-ocr-watch.sh
Restart=always
RestartSec=5
WorkingDirectory=/srv/scan

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$UNIT"
chown root:root "$UNIT"

FAX_UNIT="/etc/systemd/system/scan-ocr-fax.service"
backup_file_ts "$FAX_UNIT"
cat >"$FAX_UNIT" <<'UNIT'
[Unit]
Description=scan-ocr watcher for received faxes
After=network-online.target smbd.service asterisk.service
Wants=network-online.target

[Service]
Type=simple
User=scanocr
Group=scanocr
Environment=SCAN_OCR_IN_DIR=/srv/scan/fax-eingang
Environment=SCAN_OCR_OUT_DIR=/var/spool/asterisk/fax
Environment=SCAN_OCR_ARCH_DIR=/srv/scan/fax-archiv
Environment=SCAN_OCR_ERR_DIR=/srv/scan/fax-fehler
Environment=SCAN_OCR_WORK_DIR=/var/tmp/scan-ocr-fax
Environment="SCAN_OCR_OUTPUT_SUFFIX="
ExecStart=/usr/local/bin/scan-ocr-watch.sh
Restart=always
RestartSec=5
WorkingDirectory=/srv/scan

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$FAX_UNIT"
chown root:root "$FAX_UNIT"

SMB="/etc/samba/smb.conf"
if [ -f "$SMB" ]; then
  backup_file_ts "$SMB"
  python3 - "$SMB" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
drop = {"scan-to-ocr", "hierhin-scannen-fuer-ocr", "scan-eingang", "fax-eingang"}
out = []
skip = False
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped[1:-1].strip()
        skip = section in drop
    if not skip:
        out.append(line)

while out and out[-1].strip() == "":
    out.pop()

out.append("")
out.append("[hierhin-scannen-fuer-ocr]")
out.append("   path = /srv/scan/eingang")
out.append("   browseable = yes")
out.append("   read only = no")
out.append("   guest ok = yes")
out.append("   force user = scanocr")
out.append("   force group = scanocr")
out.append("   create mask = 0666")
out.append("   directory mask = 2777")
out.append("")
out.append("[scan-eingang]")
out.append("   path = /srv/scan/ocr")
out.append("   browseable = yes")
out.append("   read only = no")
out.append("   guest ok = yes")
out.append("   force user = scanocr")
out.append("   force group = scanocr")
out.append("   create mask = 0666")
out.append("   directory mask = 2777")
out.append("")
out.append("[fax-eingang]")
out.append("   path = /var/spool/asterisk/fax")
out.append("   browseable = yes")
out.append("   writable = yes")
out.append("   read only = no")
out.append("   guest ok = yes")
out.append("   public = yes")
out.append("   create mask = 0777")
out.append("   directory mask = 0777")
out.append("   force user = nobody")
out.append("   force group = nogroup")
out.append("")
path.write_text("\n".join(out), encoding="utf-8")
PY
fi

testparm -s >/dev/null 2>&1 || log "WARN: testparm meldet Probleme; bitte Samba-Konfiguration pruefen."
systemctl daemon-reload
systemctl enable --now scan-ocr.service
systemctl restart scan-ocr.service || true
systemctl enable --now scan-ocr-fax.service
systemctl restart scan-ocr-fax.service || true
systemctl restart smbd nmbd || true

log "[OK] Scan-OCR bereit: \\\\$(hostname)\\hierhin-scannen-fuer-ocr -> \\\\$(hostname)\\scan-eingang; Fax-OCR -> \\\\$(hostname)\\fax-eingang"

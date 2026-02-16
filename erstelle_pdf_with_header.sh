sudo tee /usr/local/bin/pdf_with_header.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   pdf_with_header.sh INPUT.pdf OUTPUT.pdf
#
# Header on EACH page:
#   Left:  "<DATE>"
#   Center:"<PRACTICE_NAME>"
#   Right: "Seite X/Y"
#
# Customize via env:
#   PRACTICE_NAME="Praxis Dr. Thomas Mustermann"
#   DATE_FMT="%d.%m.%Y %H:%M"
#   TOP_OFFSET_MM="6"     # distance from top edge to text baseline (smaller => higher)
#   FONT_NAME="Helvetica"
#   FONT_SIZE="9"
#   LEFT_MARGIN_MM="12"
#   RIGHT_MARGIN_MM="12"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 INPUT.pdf OUTPUT.pdf" >&2
  exit 2
fi

IN="$1"
OUT="$2"

if [[ ! -f "$IN" ]]; then
  echo "ERROR: input not found: $IN" >&2
  exit 2
fi

PRACTICE_NAME="${PRACTICE_NAME:-Praxis Dr. Thomas Mustermann - Tel: 0123/4567 Fax: 0123/4568}"
DATE_FMT="${DATE_FMT:-%d.%m.%Y %H:%M}"

TOP_OFFSET_MM="${TOP_OFFSET_MM:-6}"
LEFT_MARGIN_MM="${LEFT_MARGIN_MM:-12}"
RIGHT_MARGIN_MM="${RIGHT_MARGIN_MM:-12}"

FONT_NAME="${FONT_NAME:-Helvetica}"
FONT_SIZE="${FONT_SIZE:-9}"

python3 - "$IN" "$OUT" "$PRACTICE_NAME" "$DATE_FMT" \
        "$TOP_OFFSET_MM" "$LEFT_MARGIN_MM" "$RIGHT_MARGIN_MM" \
        "$FONT_NAME" "$FONT_SIZE" <<'PY'
import sys
from datetime import datetime
from pathlib import Path
from io import BytesIO

from reportlab.pdfgen import canvas
from reportlab.lib.units import mm
from reportlab.pdfbase.pdfmetrics import stringWidth

try:
    from PyPDF2 import PdfReader, PdfWriter
except ModuleNotFoundError:
    from pypdf import PdfReader, PdfWriter

in_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

practice = sys.argv[3]
date_fmt = sys.argv[4]

top_offset_mm = float(sys.argv[5])
left_margin_mm = float(sys.argv[6])
right_margin_mm = float(sys.argv[7])

font_name = sys.argv[8]
font_size = float(sys.argv[9])

reader = PdfReader(str(in_path))
total_pages = len(reader.pages)
stamp_date = datetime.now().strftime(date_fmt)

writer = PdfWriter()

def make_overlay(page_w, page_h, page_no, total_pages):
    """
    Create a single-page PDF overlay (in memory) with a 3-part header:
      left: date/time
      center: practice name
      right: page x/y
    """
    buf = BytesIO()
    c = canvas.Canvas(buf, pagesize=(page_w, page_h))

    c.setFont(font_name, font_size)

    # Baseline position: a bit closer to top than before
    y = page_h - (top_offset_mm * mm)

    left_text = stamp_date
    center_text = practice
    right_text = f"Seite {page_no}/{total_pages}"

    x_left = left_margin_mm * mm
    x_right_edge = page_w - (right_margin_mm * mm)

    # Left
    c.drawString(x_left, y, left_text)

    # Right (right-aligned)
    w_right = stringWidth(right_text, font_name, font_size)
    c.drawString(x_right_edge - w_right, y, right_text)

    # Center (centered on page)
    w_center = stringWidth(center_text, font_name, font_size)
    c.drawString((page_w - w_center) / 2.0, y, center_text)

    c.showPage()
    c.save()
    buf.seek(0)
    return PdfReader(buf).pages[0]

for idx, page in enumerate(reader.pages, start=1):
    w = float(page.mediabox.width)
    h = float(page.mediabox.height)

    overlay = make_overlay(w, h, idx, total_pages)
    page.merge_page(overlay)
    writer.add_page(page)

out_path.parent.mkdir(parents=True, exist_ok=True)
with out_path.open("wb") as f:
    writer.write(f)
PY
EOF

sudo chmod +x /usr/local/bin/pdf_with_header.sh

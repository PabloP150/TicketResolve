"""
service.py — Business logic for the reporte_pdf worker (US-06).

Generates a consolidated monthly incident report (PDF) without touching the
hot transactional path of the user-facing API: the worker runs asynchronously,
scans the META items for the requested month, computes availability/throughput
metrics, renders a PDF and stores it in the reports bucket, then returns a
short-lived presigned download URL.

Reuse:
  - The month scan mirrors the capped, paginated Scan pattern used elsewhere.
  - PDF rendering uses fpdf2 (pure-Python, no system libraries) so the Lambda
    zip stays self-contained.
  - The download link reuses shared.s3.generate_presigned_get against the
    reports bucket.

Configuration:
  REPORTS_BUCKET — destination bucket for generated PDFs (required).
"""
import logging
import os
from collections import Counter
from datetime import datetime, timezone

from boto3.dynamodb.conditions import Attr
from fpdf import FPDF
from fpdf.enums import XPos, YPos

from shared import ddb, keys, s3

logger = logging.getLogger(__name__)

# Reports may legitimately span a full month of tickets; allow a larger budget
# than the interactive dashboard scan but still bound the work.
_SCAN_MAX_PAGES: int = 50
_SCAN_MAX_ITEMS: int = 10000

_SEVERITY_ORDER = ("P0", "P1", "P2")
_STATUS_ORDER = ("OPEN", "ACK", "ESCALATED", "RESOLVED")

# Presigned report links live longer than attachment links — a manager may open
# the email later — but still expire (1 hour).
_REPORT_URL_EXPIRY_SECONDS: int = 60 * 60

_DOWNLOAD_PREFIX = "reports"


def current_month() -> str:
    """Return the current month as 'YYYY-MM' (UTC)."""
    return datetime.now(tz=timezone.utc).strftime("%Y-%m")


def _scan_month(month: str) -> list[dict]:
    """Return META items whose created_at falls in the given 'YYYY-MM' month."""
    table = ddb.get_table()
    filter_expr = (
        Attr("SK").eq(keys.SK_PREFIX_META)
        & Attr("created_at").begins_with(month)
    )

    items: list[dict] = []
    scan_kwargs: dict = {"FilterExpression": filter_expr}
    pages_read = 0

    while True:
        response = table.scan(**scan_kwargs)
        items.extend(response.get("Items", []))
        pages_read += 1

        last_key = response.get("LastEvaluatedKey")
        if not last_key or pages_read >= _SCAN_MAX_PAGES or len(items) >= _SCAN_MAX_ITEMS:
            break
        scan_kwargs["ExclusiveStartKey"] = last_key

    return items


def _build_pdf(month: str, tickets: list[dict]) -> bytes:
    """Render the monthly report as PDF bytes."""
    by_severity = Counter(t.get("severity", "?") for t in tickets)
    by_status = Counter(t.get("status", "?") for t in tickets)
    resolved = [t for t in tickets if t.get("status") == "RESOLVED"]

    pdf = FPDF()
    pdf.set_auto_page_break(auto=True, margin=15)
    pdf.add_page()

    def line(height: float, text: str) -> None:
        # new_x/new_y return the cursor to the left margin on the next line;
        # without this a w=0 multi_cell leaves X at the right margin and the
        # following call has zero usable width.
        pdf.multi_cell(0, height, text=text, new_x=XPos.LMARGIN, new_y=YPos.NEXT)

    pdf.set_font("Helvetica", "B", 18)
    line(12, "TicketResolve - Reporte mensual de incidentes")

    pdf.set_font("Helvetica", "", 11)
    generated = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    line(7, f"Periodo: {month}")
    line(7, f"Generado: {generated}")
    pdf.ln(3)

    pdf.set_font("Helvetica", "B", 13)
    line(8, "Resumen")
    pdf.set_font("Helvetica", "", 11)
    total = len(tickets)
    resolved_count = len(resolved)
    resolution_rate = (resolved_count / total * 100) if total else 0.0
    line(7, f"Total de incidentes: {total}")
    line(7, f"Resueltos: {resolved_count} ({resolution_rate:.0f}%)")
    pdf.ln(3)

    pdf.set_font("Helvetica", "B", 13)
    line(8, "Por severidad")
    pdf.set_font("Helvetica", "", 11)
    for sev in _SEVERITY_ORDER:
        line(7, f"  {sev}: {by_severity.get(sev, 0)}")
    pdf.ln(3)

    pdf.set_font("Helvetica", "B", 13)
    line(8, "Por estado")
    pdf.set_font("Helvetica", "", 11)
    for status in _STATUS_ORDER:
        line(7, f"  {status}: {by_status.get(status, 0)}")

    if total == 0:
        pdf.ln(4)
        pdf.set_font("Helvetica", "I", 11)
        line(7, "No se registraron incidentes en el periodo.")

    return bytes(pdf.output())


def generate_report(month: str | None = None) -> dict:
    """Generate, store, and link a monthly report.

    Returns {month, key, download_url, ticket_count}.
    """
    month = month or current_month()
    bucket = os.environ["REPORTS_BUCKET"]

    tickets = _scan_month(month)
    pdf_bytes = _build_pdf(month, tickets)

    key = f"{_DOWNLOAD_PREFIX}/{month}.pdf"
    s3.get_s3_client().put_object(
        Bucket=bucket,
        Key=key,
        Body=pdf_bytes,
        ContentType="application/pdf",
    )
    download_url = s3.generate_presigned_get(bucket, key, expires=_REPORT_URL_EXPIRY_SECONDS)

    logger.info(
        "Generated monthly report month=%s tickets=%d -> s3://%s/%s",
        month, len(tickets), bucket, key,
    )
    return {
        "month": month,
        "key": key,
        "download_url": download_url,
        "ticket_count": len(tickets),
    }

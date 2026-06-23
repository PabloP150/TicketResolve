"""
lambda_function.py — entry point for the reporte_pdf worker (US-06).

Invoked asynchronously (InvocationType='Event') by the api-tickets admin
endpoint POST /api/v1/reports, so the heavy scan + render never blocks an
interactive request. The invocation payload may carry {"month": "YYYY-MM"};
when absent the current month is used.

Optionally emits a REPORT_READY event to the notifications queue so the
requester can be e-mailed the download link (US-06: "envía un link por correo").

Configuration arrives through the process environment (REPORTS_BUCKET, and
optionally EVENTS_QUEUE_URL/QUEUE_URL), populated by Terraform.
"""
import logging
import os

from reporte_pdf import service
from shared import events

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def lambda_handler(event, context):
    """Generate one monthly report. Returns the report descriptor."""
    month = None
    if isinstance(event, dict):
        month = event.get("month")

    result = service.generate_report(month)

    # Best-effort: notify that the report is ready with its download link.
    try:
        events.enqueue(
            "REPORT_READY",
            ticket_id="-",
            month=result["month"],
            download_url=result["download_url"],
        )
    except Exception:  # noqa: BLE001 — notification is non-critical
        logger.exception("Failed to enqueue REPORT_READY event for %s", result.get("month"))

    return {"statusCode": 200, **result}

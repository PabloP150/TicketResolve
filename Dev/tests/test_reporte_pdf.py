"""
test_reporte_pdf.py — Tests for the reporte_pdf worker + admin trigger (US-06).

Covers:
  1. generate_report scans the month, renders a real PDF, stores it, returns a link.
  2. An empty month still produces a valid (zero-count) PDF.
  3. The worker handler delegates to the service.
  4. request_report dispatches an async Lambda invoke when wired.
  5. request_report is accepted (202) but not dispatched when unwired.
  6. An invalid month is rejected (400 via the router).
  7. POST /api/v1/reports routes to request_report (202).
"""
import json
import os

import boto3
import pytest

from shared import ids, keys

REPORTS_BUCKET = "ticketresolve-test-reports"


def _seed_ticket(table, ticket_id, month, status="OPEN", severity="P1"):
    """Put a META item whose created_at falls in the given 'YYYY-MM' month."""
    created_iso = f"{month}-15T10:00:00Z"
    table.put_item(Item={
        "PK": keys.ticket_pk(ticket_id),
        "SK": keys.meta_sk(),
        "ticket_id": ticket_id,
        "status": status,
        "severity": severity,
        "title": f"ticket {ticket_id}",
        "service": "payments",
        "assignee": "ops",
        "sla_deadline": f"{month}-15T10:15:00Z",
        "created_at": created_iso,
        "updated_at": created_iso,
        "version": 1,
    })


def _make_reports_bucket():
    boto3.client("s3", region_name="us-east-1").create_bucket(Bucket=REPORTS_BUCKET)
    os.environ["REPORTS_BUCKET"] = REPORTS_BUCKET


# ---------------------------------------------------------------------------
# 1 — generate_report produces and stores a PDF
# ---------------------------------------------------------------------------

def test_generate_report_creates_pdf(aws_services):
    table, s3_client = aws_services
    _make_reports_bucket()
    from reporte_pdf import service
    try:
        _seed_ticket(table, "TKT-1", "2026-06", status="RESOLVED", severity="P0")
        _seed_ticket(table, "TKT-2", "2026-06", status="OPEN", severity="P1")
        _seed_ticket(table, "TKT-3", "2026-05", status="OPEN")  # different month

        result = service.generate_report("2026-06")

        assert result["month"] == "2026-06"
        assert result["ticket_count"] == 2
        assert result["key"] == "reports/2026-06.pdf"
        assert result["download_url"].startswith("https://")

        obj = s3_client.get_object(Bucket=REPORTS_BUCKET, Key="reports/2026-06.pdf")
        data = obj["Body"].read()
        assert data[:4] == b"%PDF"
        assert len(data) > 500
    finally:
        os.environ.pop("REPORTS_BUCKET", None)


# ---------------------------------------------------------------------------
# 2 — empty month still produces a valid PDF
# ---------------------------------------------------------------------------

def test_generate_report_empty_month(aws_services):
    table, s3_client = aws_services
    _make_reports_bucket()
    from reporte_pdf import service
    try:
        result = service.generate_report("2030-01")
        assert result["ticket_count"] == 0
        data = s3_client.get_object(Bucket=REPORTS_BUCKET, Key="reports/2030-01.pdf")["Body"].read()
        assert data[:4] == b"%PDF"
    finally:
        os.environ.pop("REPORTS_BUCKET", None)


# ---------------------------------------------------------------------------
# 3 — worker handler delegates to the service
# ---------------------------------------------------------------------------

def test_worker_handler_generates(aws_services):
    table, _ = aws_services
    _make_reports_bucket()
    from reporte_pdf.lambda_function import lambda_handler
    try:
        _seed_ticket(table, "TKT-H", "2026-06")
        resp = lambda_handler({"month": "2026-06"}, {})
        assert resp["statusCode"] == 200
        assert resp["month"] == "2026-06"
        assert resp["ticket_count"] == 1
    finally:
        os.environ.pop("REPORTS_BUCKET", None)


# ---------------------------------------------------------------------------
# 4 — request_report dispatches an async invoke when wired
# ---------------------------------------------------------------------------

def test_request_report_dispatches(aws_services, monkeypatch):
    from api_tickets import service

    calls = {}

    class _FakeLambda:
        def invoke(self, **kwargs):
            calls.update(kwargs)
            return {"StatusCode": 202}

    monkeypatch.setattr(service, "_get_lambda_client", lambda: _FakeLambda())
    monkeypatch.setenv("REPORT_FUNCTION_NAME", "ticketresolve-dev-reporte-pdf")

    result, status = service.request_report({"month": "2026-06"})

    assert status == 202
    assert result["dispatched"] is True
    assert calls["FunctionName"] == "ticketresolve-dev-reporte-pdf"
    assert calls["InvocationType"] == "Event"
    assert json.loads(calls["Payload"]) == {"month": "2026-06"}


# ---------------------------------------------------------------------------
# 5 — accepted but not dispatched when unwired
# ---------------------------------------------------------------------------

def test_request_report_not_dispatched_when_unwired(aws_services, monkeypatch):
    from api_tickets import service
    monkeypatch.delenv("REPORT_FUNCTION_NAME", raising=False)

    result, status = service.request_report({})
    assert status == 202
    assert result["dispatched"] is False
    assert result["month"] == "current"


# ---------------------------------------------------------------------------
# 6 — invalid month rejected (400 via router)
# ---------------------------------------------------------------------------

def test_request_report_invalid_month(aws_services):
    from api_tickets.lambda_function import lambda_handler
    from conftest import make_event

    resp = lambda_handler(
        make_event("POST", "/api/v1/reports", body={"month": "2026-13"}), {}
    )
    assert resp["statusCode"] == 400


# ---------------------------------------------------------------------------
# 7 — POST /api/v1/reports routes to request_report (202)
# ---------------------------------------------------------------------------

def test_route_post_reports(aws_services, monkeypatch):
    from api_tickets.lambda_function import lambda_handler
    from conftest import make_event
    monkeypatch.delenv("REPORT_FUNCTION_NAME", raising=False)

    resp = lambda_handler(make_event("POST", "/api/v1/reports", body={}), {})
    assert resp["statusCode"] == 202
    assert json.loads(resp["body"])["status"] == "accepted"

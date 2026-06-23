"""
test_escalamiento.py — Tests for the SLA-breach escalation worker (US-04).

Covers:
  1. Overdue OPEN ticket is auto-escalated (status, version bump, EVENT).
  2. Overdue ACK ticket is auto-escalated.
  3. Ticket still within SLA is left untouched.
  4. RESOLVED ticket (even if overdue) is ignored.
  5. Already-ESCALATED ticket is not re-escalated.
  6. Idempotency: a second sweep does not escalate the same ticket again.
  7. Notification: an ESCALATED event is enqueued to SQS when a queue is wired.
  8. Mixed table: only the overdue/escalatable tickets are counted.
"""
import json
import os

import boto3
import pytest

from shared import ddb, events, ids, keys, models


def _put_ticket(table, ticket_id, status, sla_offset_minutes, version=1,
                severity="P1", assignee="ops-agent"):
    """Write a META item directly, with sla_deadline offset from 'now'.

    A negative offset puts the deadline in the past (overdue); a positive one in
    the future. Mirrors the real META shape written by api_tickets.create_ticket.
    """
    from datetime import timedelta
    now = ids.utc_now()
    created_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    sla_iso = (now + timedelta(minutes=sla_offset_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")

    table.put_item(Item={
        "PK": keys.ticket_pk(ticket_id),
        "SK": keys.meta_sk(),
        "ticket_id": ticket_id,
        "status": status,
        "severity": severity,
        "title": f"ticket {ticket_id}",
        "service": "payments",
        "assignee": assignee,
        "sla_deadline": sla_iso,
        "created_at": created_iso,
        "updated_at": created_iso,
        "version": version,
        "GSI1PK": keys.gsi1_pk(assignee),
        "GSI1SK": keys.gsi1_sk(status, sla_iso),
    })


def _get_meta(table, ticket_id):
    return table.get_item(
        Key={"PK": keys.ticket_pk(ticket_id), "SK": keys.meta_sk()}
    )["Item"]


def _events_for(table, ticket_id):
    from boto3.dynamodb.conditions import Key
    resp = table.query(
        KeyConditionExpression=(
            Key("PK").eq(keys.ticket_pk(ticket_id))
            & Key("SK").begins_with(keys.SK_PREFIX_EVENT)
        )
    )
    return resp.get("Items", [])


def _sweep():
    from escalamiento import service
    return service.sweep_overdue()


# ---------------------------------------------------------------------------
# 1 & 2 — overdue tickets escalate
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("status", ["OPEN", "ACK"])
def test_overdue_ticket_escalates(aws_services, status):
    table, _ = aws_services
    _put_ticket(table, "TKT-OVERDUE1", status, sla_offset_minutes=-10, version=3)

    summary = _sweep()

    assert summary["escalated"] == 1
    meta = _get_meta(table, "TKT-OVERDUE1")
    assert meta["status"] == "ESCALATED"
    assert int(meta["version"]) == 4  # optimistic-lock bump
    assert meta["GSI1SK"].startswith("STATUS#ESCALATED#")

    ev_types = [e["event_type"] for e in _events_for(table, "TKT-OVERDUE1")]
    assert "ESCALATED" in ev_types


# ---------------------------------------------------------------------------
# 3 — within SLA is untouched
# ---------------------------------------------------------------------------

def test_within_sla_not_escalated(aws_services):
    table, _ = aws_services
    _put_ticket(table, "TKT-FRESH", "OPEN", sla_offset_minutes=+60)

    summary = _sweep()

    assert summary["escalated"] == 0
    assert _get_meta(table, "TKT-FRESH")["status"] == "OPEN"


# ---------------------------------------------------------------------------
# 4 — RESOLVED ignored even if overdue
# ---------------------------------------------------------------------------

def test_resolved_overdue_ignored(aws_services):
    table, _ = aws_services
    _put_ticket(table, "TKT-DONE", "RESOLVED", sla_offset_minutes=-120)

    summary = _sweep()

    assert summary["escalated"] == 0
    assert _get_meta(table, "TKT-DONE")["status"] == "RESOLVED"


# ---------------------------------------------------------------------------
# 5 — already ESCALATED not re-escalated
# ---------------------------------------------------------------------------

def test_already_escalated_not_reescalated(aws_services):
    table, _ = aws_services
    _put_ticket(table, "TKT-ESC", "ESCALATED", sla_offset_minutes=-30, version=2)

    summary = _sweep()

    assert summary["escalated"] == 0
    meta = _get_meta(table, "TKT-ESC")
    assert int(meta["version"]) == 2  # untouched


# ---------------------------------------------------------------------------
# 6 — idempotency across overlapping sweeps
# ---------------------------------------------------------------------------

def test_double_sweep_escalates_once(aws_services):
    table, _ = aws_services
    _put_ticket(table, "TKT-IDEM", "OPEN", sla_offset_minutes=-5, version=1)

    first = _sweep()
    second = _sweep()

    assert first["escalated"] == 1
    assert second["escalated"] == 0
    assert int(_get_meta(table, "TKT-IDEM")["version"]) == 2


# ---------------------------------------------------------------------------
# 7 — notification enqueued to SQS
# ---------------------------------------------------------------------------

def test_escalation_enqueues_notification(aws_services):
    table, _ = aws_services
    sqs = boto3.client("sqs", region_name="us-east-1")
    queue_url = sqs.create_queue(QueueName="ticketresolve-test-events")["QueueUrl"]

    os.environ["EVENTS_QUEUE_URL"] = queue_url
    events.reset()
    try:
        _put_ticket(table, "TKT-NOTIFY", "OPEN", sla_offset_minutes=-1, severity="P0")
        _sweep()

        msgs = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10).get("Messages", [])
        assert len(msgs) == 1
        payload = json.loads(msgs[0]["Body"])
        assert payload["type"] == "ESCALATED"
        assert payload["ticket_id"] == "TKT-NOTIFY"
        assert payload["severity"] == "P0"
    finally:
        os.environ.pop("EVENTS_QUEUE_URL", None)
        events.reset()


# ---------------------------------------------------------------------------
# 8 — mixed table, only overdue+escalatable counted
# ---------------------------------------------------------------------------

def test_mixed_table_counts(aws_services):
    table, _ = aws_services
    _put_ticket(table, "TKT-A", "OPEN", sla_offset_minutes=-10)   # escalates
    _put_ticket(table, "TKT-B", "ACK", sla_offset_minutes=-5)     # escalates
    _put_ticket(table, "TKT-C", "OPEN", sla_offset_minutes=+30)   # fresh
    _put_ticket(table, "TKT-D", "RESOLVED", sla_offset_minutes=-99)  # terminal

    summary = _sweep()

    assert summary["scanned"] == 2
    assert summary["escalated"] == 2
    assert summary["skipped"] == 0

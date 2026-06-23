"""
service.py — Business logic for the escalamiento (SLA-breach escalation) worker.

This is the background half of the hierarchical escalation engine (US-04, the
"motor de escalamiento" detailed in §15 of the cloud design). The EventBridge
Scheduler invokes the worker on a fixed cadence; each run sweeps the table for
tickets whose SLA deadline has passed while they are still un-resolved and
auto-transitions them to ESCALATED.

Design reuse:
  - Overdue detection reuses the same paginated, hard-capped Scan pattern as
    api_tickets.list_dashboard (no assignee → full-table Scan). A status-keyed
    GSI would be cheaper at scale and is deferred to the same future iteration
    noted there.
  - The state mutation reuses the optimistic-locking + state-machine contract
    of api_tickets.service.update_status: a single conditional Update that only
    succeeds when the version still matches and the current status is a valid
    source for ESCALATED. Concurrent manual actions therefore can never be
    silently overwritten — a losing race is simply skipped this cycle.
  - On success the worker emits an ESCALATED event to the notifications queue
    (shared.events) so the notificacion worker can alert the next on-call tier.
"""
import logging
import os

from boto3.dynamodb.conditions import Attr
from boto3.dynamodb.types import TypeSerializer

from shared import ddb, events, ids, keys, models

logger = logging.getLogger(__name__)

_SERIALIZER = TypeSerializer()

# Safety caps for the full-table Scan, mirroring list_dashboard. Bounds the work
# a single scheduler invocation performs even on a pathologically large table.
_SCAN_MAX_PAGES: int = 20
_SCAN_MAX_ITEMS: int = 2000

# Statuses from which an un-resolved ticket may still be auto-escalated.
# RESOLVED is terminal; ESCALATED is already at the escalated state.
_ESCALATABLE_STATUSES: frozenset = frozenset({"OPEN", "ACK"})


def _serialize(item: dict) -> dict:
    """Serialize a plain dict to DynamoDB wire format for transact/update calls."""
    return {k: _SERIALIZER.serialize(v) for k, v in item.items()}


def _scan_overdue(now_iso: str) -> list[dict]:
    """Return META items that are overdue (sla_deadline < now) and escalatable.

    Uses a paginated, capped Scan with a server-side FilterExpression so only
    matching META items cross the wire. Sorted ascending by sla_deadline so the
    most-overdue tickets are escalated first within a single run.
    """
    table = ddb.get_table()

    filter_expr = (
        Attr("SK").eq(keys.SK_PREFIX_META)
        & Attr("status").is_in(list(_ESCALATABLE_STATUSES))
        & Attr("sla_deadline").lt(now_iso)
    )

    overdue: list[dict] = []
    scan_kwargs: dict = {"FilterExpression": filter_expr}
    pages_read = 0

    while True:
        response = table.scan(**scan_kwargs)
        overdue.extend(response.get("Items", []))
        pages_read += 1

        last_key = response.get("LastEvaluatedKey")
        if not last_key or pages_read >= _SCAN_MAX_PAGES or len(overdue) >= _SCAN_MAX_ITEMS:
            if last_key and (pages_read >= _SCAN_MAX_PAGES or len(overdue) >= _SCAN_MAX_ITEMS):
                logger.warning(
                    "Escalation sweep capped at %d pages / %d items. "
                    "Deploy a status-keyed GSI to eliminate this scan.",
                    pages_read, len(overdue),
                )
            break

        scan_kwargs["ExclusiveStartKey"] = last_key

    overdue.sort(key=lambda x: x.get("sla_deadline", ""))
    return overdue


def _escalate_one(meta: dict, now_iso: str) -> bool:
    """Atomically transition a single overdue ticket to ESCALATED.

    Returns True if this run escalated the ticket, False if a concurrent change
    (version moved, or status is no longer escalatable) made the conditional
    write fail — in which case the ticket is left to the next cycle / manual flow.
    """
    ticket_id = meta.get("ticket_id")
    pk = keys.ticket_pk(ticket_id)
    current_status = meta.get("status", "")
    current_version = int(meta.get("version", 0))
    sla_deadline = meta.get("sla_deadline", "")

    table_name = os.environ["TABLE_NAME"]
    client = ddb.get_client()
    u8 = ids.short_uuid8()
    new_gsi1_sk = keys.gsi1_sk(models.ESCALATED_STATUS, sla_deadline)

    event_item = {
        "PK": pk,
        "SK": keys.event_sk(now_iso, u8),
        "event_type": "ESCALATED",
        "actor": models.SYSTEM_ACTOR,
        "action": "Ticket escalado automáticamente por vencimiento de SLA",
        "payload": {"previous_status": current_status, "sla_deadline": sla_deadline},
        "created_at": now_iso,
    }

    transact_items = [
        {
            "Update": {
                "TableName": table_name,
                "Key": _serialize({"PK": pk, "SK": keys.meta_sk()}),
                "UpdateExpression": (
                    "SET #st = :target, updated_at = :now, #ver = :new_ver, GSI1SK = :new_gsi1sk"
                ),
                # Conditional: version unchanged AND still in an escalatable state.
                # Closes the TOCTOU window between the Scan read and this write.
                "ConditionExpression": (
                    "#ver = :expected_ver AND (#st = :src_open OR #st = :src_ack)"
                ),
                "ExpressionAttributeNames": {"#st": "status", "#ver": "version"},
                "ExpressionAttributeValues": _serialize({
                    ":target": models.ESCALATED_STATUS,
                    ":now": now_iso,
                    ":new_ver": current_version + 1,
                    ":expected_ver": current_version,
                    ":new_gsi1sk": new_gsi1_sk,
                    ":src_open": "OPEN",
                    ":src_ack": "ACK",
                }),
            }
        },
        {"Put": {"TableName": table_name, "Item": _serialize(event_item)}},
    ]

    try:
        client.transact_write_items(TransactItems=transact_items)
    except client.exceptions.TransactionCanceledException:
        # Lost the race (manual ACK/RESOLVE/version bump in flight). Skip; the
        # next sweep re-evaluates. Not an error condition.
        logger.info(
            "Skipped %s — concurrent change (status=%s version=%s)",
            ticket_id, current_status, current_version,
        )
        return False

    # Best-effort notification; a queue failure must not roll back the escalation.
    events.enqueue(
        "ESCALATED",
        ticket_id,
        severity=meta.get("severity"),
        assignee=meta.get("assignee"),
        title=meta.get("title"),
        previous_status=current_status,
    )

    logger.info(
        "Escalated %s (%s → ESCALATED) — SLA breached at %s",
        ticket_id, current_status, sla_deadline,
    )
    return True


def sweep_overdue() -> dict:
    """Find and escalate every overdue, un-resolved ticket.

    Returns a summary {scanned, escalated, skipped} for logging / smoke tests.
    Idempotent across overlapping runs: the per-ticket conditional write means a
    ticket can be escalated at most once even if two sweeps overlap.
    """
    now = ids.utc_now()
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    candidates = _scan_overdue(now_iso)
    escalated = 0
    for meta in candidates:
        if _escalate_one(meta, now_iso):
            escalated += 1

    summary = {
        "scanned": len(candidates),
        "escalated": escalated,
        "skipped": len(candidates) - escalated,
    }
    logger.info("SLA sweep complete: %s", summary)
    return summary

"""
service.py — Business logic for the notificacion worker (US-05).

The worker consumes domain events off the SQS notifications queue (produced by
api_tickets on RESOLVED/ESCALATED transitions and by the escalamiento worker on
automatic escalation) and fans them out as human-readable email notifications
via an SNS topic.

SNS topic + email subscription is the multi-channel entry point described in the
cloud design (§14 SNS fan-out). SES/SMS are future channels behind the same
event contract.

Configuration:
  SNS_TOPIC_ARN — target topic. When unset (local tests / async-less deploy)
  publishing is a no-op so the consumer still drains the queue without error.
"""
import json
import logging
import os
from typing import Any

import boto3

logger = logging.getLogger(__name__)

_sns: Any = None

# Per-event-type presentation. Subjects are kept short and ASCII-only because
# SNS limits Subject to 100 chars; the richer wording lives in the body.
_TEMPLATES: dict[str, dict[str, str]] = {
    "ESCALATED": {
        "subject": "[TicketResolve] Ticket escalado",
        "headline": "Un ticket fue escalado y requiere atención del siguiente nivel.",
    },
    "RESOLVED": {
        "subject": "[TicketResolve] Ticket resuelto",
        "headline": "Un ticket fue marcado como resuelto. Ciclo de vida cerrado.",
    },
    "ALERT_DUPLICATE": {
        "subject": "[TicketResolve] Alerta duplicada",
        "headline": "Se recibió una alerta duplicada sobre un incidente activo.",
    },
}

_DEFAULT_TEMPLATE = {
    "subject": "[TicketResolve] Notificación de incidente",
    "headline": "Actualización de un incidente.",
}


def get_sns():
    """Return (lazily initialised) boto3 SNS client."""
    global _sns
    if _sns is None:
        _sns = boto3.client("sns")
    return _sns


def reset() -> None:
    """Reset cached SNS client — call in test teardown when moto context changes."""
    global _sns
    _sns = None


def _format(event: dict) -> tuple[str, str]:
    """Build (subject, body) for a domain event."""
    event_type = event.get("type", "UNKNOWN")
    tmpl = _TEMPLATES.get(event_type, _DEFAULT_TEMPLATE)

    lines = [tmpl["headline"], ""]
    for label, key in (
        ("Ticket", "ticket_id"),
        ("Severidad", "severity"),
        ("Título", "title"),
        ("Estado previo", "previous_status"),
        ("Responsable", "assignee"),
        ("Actor", "actor"),
    ):
        value = event.get(key)
        if value:
            lines.append(f"{label}: {value}")

    return tmpl["subject"], "\n".join(lines)


def process_record(record: dict) -> str | None:
    """Parse one SQS record and publish its notification to SNS.

    Returns the SNS MessageId, or None when no topic is configured (no-op).
    Raises on malformed JSON or an SNS publish failure so the caller can report
    the record for retry / DLQ.
    """
    body = record.get("body", "")
    event = json.loads(body)  # raises on malformed payload → reported as failure

    topic_arn = os.environ.get("SNS_TOPIC_ARN")
    if not topic_arn:
        logger.debug("SNS_TOPIC_ARN unset; skipping publish for %s", event.get("type"))
        return None

    subject, message = _format(event)
    response = get_sns().publish(TopicArn=topic_arn, Subject=subject, Message=message)
    message_id = response.get("MessageId")
    logger.info(
        "published notification type=%s ticket=%s sns_message_id=%s",
        event.get("type"), event.get("ticket_id"), message_id,
    )
    return message_id

"""
events.py — Publish domain events to the SQS notifications queue.

Producers enqueue a structured domain event here:
  - the api-tickets slice on RESOLVED / manual ESCALATED transitions,
  - the escalamiento worker on automatic SLA-breach escalation.

The notificacion worker consumes this queue and fans the events out to SNS
(email). Keeping a single tiny publisher here means every producer emits the
same message shape and the queue URL is resolved in exactly one place.

The queue URL is read from the EVENTS_QUEUE_URL env var (falling back to the
legacy QUEUE_URL name that the Delivery-4 infra already injects). When neither
is set — local unit tests, or a deployment without async wiring — publishing is
a no-op that returns None, so the transactional write path never fails because
of a missing queue.
"""
import json
import logging
import os
from typing import Any

import boto3

logger = logging.getLogger(__name__)

_client: Any = None


def get_client() -> Any:
    """Return (lazily initialised) boto3 SQS client."""
    global _client
    if _client is None:
        _client = boto3.client("sqs")
    return _client


def _queue_url() -> str | None:
    return os.environ.get("EVENTS_QUEUE_URL") or os.environ.get("QUEUE_URL")


def enqueue(event_type: str, ticket_id: str, **fields: Any) -> str | None:
    """Publish a domain event to the notifications queue.

    Returns the SQS MessageId, or None when no queue is configured (no-op).
    Never raises on a missing queue so callers on the transactional path are
    not coupled to async availability.
    """
    queue_url = _queue_url()
    if not queue_url:
        logger.debug("No events queue configured; skipping publish (type=%s)", event_type)
        return None

    message = {"type": event_type, "ticket_id": ticket_id, **fields}
    response = get_client().send_message(
        QueueUrl=queue_url,
        MessageBody=json.dumps(message, default=str),
    )
    message_id = response.get("MessageId")
    logger.info(
        "enqueued event type=%s ticket=%s message_id=%s",
        event_type, ticket_id, message_id,
    )
    return message_id


def reset() -> None:
    """Reset cached client — call in test teardown when moto context changes."""
    global _client
    _client = None

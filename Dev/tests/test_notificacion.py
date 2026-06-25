"""
test_notificacion.py — Tests for the notificacion worker (US-05).

Covers:
  1. A valid event publishes to SNS (verified via an SQS subscription).
  2. No SNS_TOPIC_ARN configured → process_record is a no-op (returns None).
  3. Malformed JSON body raises (so the handler reports it for retry).
  4. The batch handler isolates a poison record via batchItemFailures.
  5. Message formatting picks the right subject per event type.
  6. Integration: resolving a ticket via api_tickets enqueues a RESOLVED event.
"""
import json
import os

import boto3
import pytest

from shared import events


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _record(event: dict, message_id="m-1") -> dict:
    return {"messageId": message_id, "body": json.dumps(event)}


def _make_topic_with_sqs():
    """Create an SNS topic with an SQS subscription (raw delivery) and return
    (topic_arn, sqs_client, queue_url) so tests can read what was published."""
    sns = boto3.client("sns", region_name="us-east-1")
    sqs = boto3.client("sqs", region_name="us-east-1")
    topic_arn = sns.create_topic(Name="ticketresolve-test-notify")["TopicArn"]
    queue_url = sqs.create_queue(QueueName="notify-sink")["QueueUrl"]
    queue_arn = sqs.get_queue_attributes(
        QueueUrl=queue_url, AttributeNames=["QueueArn"]
    )["Attributes"]["QueueArn"]
    sns.subscribe(
        TopicArn=topic_arn, Protocol="sqs", Endpoint=queue_arn,
        Attributes={"RawMessageDelivery": "true"},
    )
    return topic_arn, sqs, queue_url


# ---------------------------------------------------------------------------
# 1 — valid event publishes to SNS
# ---------------------------------------------------------------------------

def test_process_record_publishes_to_sns(aws_services):
    from notificacion import service
    topic_arn, sqs, queue_url = _make_topic_with_sqs()

    os.environ["SNS_TOPIC_ARN"] = topic_arn
    service.reset()
    try:
        event = {"type": "ESCALATED", "ticket_id": "TKT-1", "severity": "P0"}
        message_id = service.process_record(_record(event))
        assert message_id is not None

        msgs = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10).get("Messages", [])
        assert len(msgs) == 1
        assert "TKT-1" in msgs[0]["Body"]
        assert "P0" in msgs[0]["Body"]
    finally:
        os.environ.pop("SNS_TOPIC_ARN", None)
        service.reset()


# ---------------------------------------------------------------------------
# 2 — no topic → no-op
# ---------------------------------------------------------------------------

def test_no_topic_is_noop(aws_services):
    from notificacion import service
    os.environ.pop("SNS_TOPIC_ARN", None)
    service.reset()

    result = service.process_record(_record({"type": "RESOLVED", "ticket_id": "TKT-2"}))
    assert result is None


# ---------------------------------------------------------------------------
# 3 — malformed JSON raises
# ---------------------------------------------------------------------------

def test_malformed_body_raises(aws_services):
    from notificacion import service
    with pytest.raises(json.JSONDecodeError):
        service.process_record({"messageId": "bad", "body": "not-json{"})


# ---------------------------------------------------------------------------
# 4 — batch handler isolates poison records
# ---------------------------------------------------------------------------

def test_handler_reports_poison_record(aws_services):
    from notificacion.lambda_function import lambda_handler
    os.environ.pop("SNS_TOPIC_ARN", None)  # good records are no-ops, still succeed

    event = {"Records": [
        _record({"type": "RESOLVED", "ticket_id": "TKT-OK"}, message_id="ok"),
        {"messageId": "poison", "body": "{broken"},
    ]}
    result = lambda_handler(event, {})

    assert result["batchItemFailures"] == [{"itemIdentifier": "poison"}]


# ---------------------------------------------------------------------------
# 5 — subject per event type
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("event_type,expected_fragment", [
    ("ESCALATED", "escalado"),
    ("RESOLVED", "resuelto"),
    ("ALERT_DUPLICATE", "duplicada"),
    ("SOMETHING_ELSE", "Notificación"),
])
def test_format_subject_by_type(event_type, expected_fragment):
    from notificacion import service
    subject, body = service._format({"type": event_type, "ticket_id": "TKT-X"})
    assert expected_fragment.lower() in subject.lower()
    assert "TKT-X" in body


# ---------------------------------------------------------------------------
# 6 — integration: resolving a ticket enqueues a RESOLVED event
# ---------------------------------------------------------------------------

def test_resolve_enqueues_event(aws_services):
    table, _ = aws_services
    from api_tickets.lambda_function import lambda_handler
    from conftest import make_event

    sqs = boto3.client("sqs", region_name="us-east-1")
    queue_url = sqs.create_queue(QueueName="ticketresolve-test-events")["QueueUrl"]
    os.environ["EVENTS_QUEUE_URL"] = queue_url
    events.reset()
    try:
        # Create a ticket through the real API
        create = lambda_handler(
            make_event("POST", "/api/v1/incidents",
                       body={"title": "xyz", "description": "y", "severity": "P1",
                             "service": "payments"}),
            {},
        )
        ticket_id = json.loads(create["body"])["ticket_id"]

        # Resolve it
        resolve = lambda_handler(
            make_event("PATCH", f"/api/v1/incidents/{ticket_id}",
                       body={"status": "RESOLVED", "actor": "ops", "version": 1}),
            {},
        )
        assert resolve["statusCode"] == 200

        msgs = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10).get("Messages", [])
        assert len(msgs) == 1
        payload = json.loads(msgs[0]["Body"])
        assert payload["type"] == "RESOLVED"
        assert payload["ticket_id"] == ticket_id
    finally:
        os.environ.pop("EVENTS_QUEUE_URL", None)
        events.reset()

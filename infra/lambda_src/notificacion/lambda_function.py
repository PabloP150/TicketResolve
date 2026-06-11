"""notificacion handler — Delivery 4 async consumer.

This function is invoked asynchronously by an SQS event source mapping (it is
NOT reachable over HTTP). For every record the event source mapping delivers,
it:

  1. reads the message payload (the JSON the producer enqueued),
  2. writes a single object to the attachments S3 bucket, keyed by the SQS
     message id, and
  3. logs the processed message id.

If the handler raises, the event source mapping returns the batch to the queue;
after max_receive_count failed receives the redrive_policy moves the message to
the dead-letter queue.

Configuration is read from the process environment, populated by Terraform from
var.* / <env>.tfvars (ATTACHMENTS_BUCKET) — nothing hardcoded. The execution
role is scoped to exactly this bucket and the events queue.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

ATTACHMENTS_BUCKET = os.environ["ATTACHMENTS_BUCKET"]

_s3 = boto3.client("s3")


def _process_record(record):
    """Persist one SQS record to S3 and return the object key."""
    message_id = record["messageId"]
    body = record.get("body", "")

    # The object key is derived from the SQS message id so it is unique and
    # traceable back to the queue record.
    key = f"events/{message_id}.json"

    document = {
        "message_id": message_id,
        "body": body,
        "source_queue_arn": record.get("eventSourceARN"),
    }

    _s3.put_object(
        Bucket=ATTACHMENTS_BUCKET,
        Key=key,
        Body=json.dumps(document).encode("utf-8"),
        ContentType="application/json",
    )

    logger.info("processed message_id=%s -> s3://%s/%s", message_id, ATTACHMENTS_BUCKET, key)
    return key


def lambda_handler(event, context):
    """Entry point for the SQS event source mapping.

    `event["Records"]` is the batch of SQS messages. The mapping is configured
    with ReportBatchItemFailures, so this returns a `batchItemFailures` list: any
    record that fails to process is reported by its messageId and only that
    message is returned to the queue (eventually the DLQ after max_receive_count),
    while the rest of the batch is deleted. An empty list means full success.
    """
    failures = []
    for record in event.get("Records", []):
        try:
            _process_record(record)
        except Exception:  # noqa: BLE001 — isolate one poison record, keep the batch
            logger.exception("failed to process message_id=%s", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}

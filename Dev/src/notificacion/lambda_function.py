"""
lambda_function.py — entry point for the notificacion worker (US-05).

Invoked asynchronously by an SQS event source mapping (NOT reachable over HTTP).
For each record in the batch it publishes a notification to SNS. The mapping is
configured with ReportBatchItemFailures, so the handler returns a
batchItemFailures list: any record that fails to process is returned to the
queue by its messageId (eventually the DLQ after max_receive_count) while the
rest of the batch is deleted. An empty list means full success.

Configuration arrives through the process environment (SNS_TOPIC_ARN),
populated by Terraform — nothing is hardcoded here.
"""
import logging
import os

from notificacion import service

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def lambda_handler(event, context):
    """Drain an SQS batch, isolating poison records via batchItemFailures."""
    failures = []
    for record in event.get("Records", []):
        try:
            service.process_record(record)
        except Exception:  # noqa: BLE001 — isolate one poison record, keep the batch
            logger.exception("failed to process message_id=%s", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}

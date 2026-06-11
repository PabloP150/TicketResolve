"""api-tickets handler — Delivery 3 connectivity proof + Delivery 4 producer.

Endpoints, all reachable only through the API Gateway HTTP API ingress:

* GET  /api/v1/incidents          -> reads the seed ticket from DynamoDB, returns it as JSON.
* POST /api/v1/incidents          -> writes the request body to the attachments S3 bucket,
                                      returns HTTP 201 with the object key.
* POST /api/v1/incidents/enqueue  -> (Delivery 4 producer) puts the JSON body on the SQS
                                      events queue, returns HTTP 202 with the real MessageId.

All configuration arrives through the process environment, which Terraform
populates from var.* / <env>.tfvars (TABLE_NAME, ATTACHMENTS_BUCKET, QUEUE_URL)
— nothing is hardcoded here. The execution role is scoped to exactly this
table, bucket and queue.
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
ATTACHMENTS_BUCKET = os.environ["ATTACHMENTS_BUCKET"]
# Delivery 4: the SQS events queue URL, injected by Terraform from the async
# module output. The producer endpoint enqueues here.
QUEUE_URL = os.environ["QUEUE_URL"]

# Region comes from the Lambda runtime (AWS_REGION) — no hardcoded region.
_dynamodb = boto3.resource("dynamodb")
_table = _dynamodb.Table(TABLE_NAME)
_s3 = boto3.client("s3")
_sqs = boto3.client("sqs")

# Key of the seed item provisioned via the aws_dynamodb_table_item resource.
SEED_PK = "TICKET#seed"
SEED_SK = "META"


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _handle_get_incidents():
    """Read at least one item from DynamoDB and return it as JSON."""
    result = _table.get_item(Key={"PK": SEED_PK, "SK": SEED_SK})
    item = result.get("Item")
    if not item:
        return _response(404, {"error": "seed ticket not found", "table": TABLE_NAME})
    return _response(200, {"source": "dynamodb", "table": TABLE_NAME, "item": item})


def _handle_post_incidents(raw_body):
    """Write a single object to S3 and return 201 with the object key."""
    try:
        payload = json.loads(raw_body) if raw_body else {}
    except (ValueError, TypeError):
        return _response(400, {"error": "request body must be valid JSON"})

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    key = f"attachments/{timestamp}-{uuid.uuid4().hex}.json"

    _s3.put_object(
        Bucket=ATTACHMENTS_BUCKET,
        Key=key,
        Body=json.dumps(payload).encode("utf-8"),
        ContentType="application/json",
    )

    return _response(201, {"source": "s3", "bucket": ATTACHMENTS_BUCKET, "key": key})


def _handle_enqueue(raw_body):
    """Delivery 4 producer: put the JSON body on the SQS queue, return 202.

    The MessageId returned is the real id SQS assigns — it is not synthesized
    here. A consumer (the notificacion Lambda, wired via an event source
    mapping) later reads this message and writes an object to S3.
    """
    try:
        payload = json.loads(raw_body) if raw_body else {}
    except (ValueError, TypeError):
        return _response(400, {"error": "request body must be valid JSON"})

    result = _sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(payload),
    )

    return _response(202, {
        "source": "sqs",
        "queue_url": QUEUE_URL,
        "message_id": result["MessageId"],
    })


def lambda_handler(event, context):
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "GET")
    path = event.get("rawPath", "/")

    if method == "POST" and path.endswith("/enqueue"):
        return _handle_enqueue(event.get("body"))

    if method == "GET" and "incidents" in path:
        return _handle_get_incidents()

    if method == "POST" and "incidents" in path:
        return _handle_post_incidents(event.get("body"))

    # Health / readiness check (e.g. GET /). Does not touch the database.
    return _response(200, {"status": "ok", "service": "api-tickets"})

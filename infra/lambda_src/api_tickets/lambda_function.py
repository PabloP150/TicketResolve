"""api-tickets handler — Delivery 3 end-to-end connectivity proof.

Two endpoints, both reachable only through the API Gateway HTTP API ingress:

* GET  /api/v1/incidents  -> reads the seed ticket from DynamoDB, returns it as JSON.
* POST /api/v1/incidents  -> writes the request body to the attachments S3 bucket,
                             returns HTTP 201 with the object key.

All configuration arrives through the process environment, which Terraform
populates from var.* / dev.tfvars (TABLE_NAME, ATTACHMENTS_BUCKET) — nothing is
hardcoded here. The execution role is scoped to exactly this table and bucket.
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
ATTACHMENTS_BUCKET = os.environ["ATTACHMENTS_BUCKET"]

# Region comes from the Lambda runtime (AWS_REGION) — no hardcoded region.
_dynamodb = boto3.resource("dynamodb")
_table = _dynamodb.Table(TABLE_NAME)
_s3 = boto3.client("s3")

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


def lambda_handler(event, context):
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "GET")
    path = event.get("rawPath", "/")

    if method == "GET" and "incidents" in path:
        return _handle_get_incidents()

    if method == "POST" and "incidents" in path:
        return _handle_post_incidents(event.get("body"))

    # Health / readiness check (e.g. GET /). Does not touch the database.
    return _response(200, {"status": "ok", "service": "api-tickets"})

"""
lambda_function.py — entry point for the escalamiento (SLA escalation) worker.

Invoked on a fixed cadence by the EventBridge Scheduler (sla_sweep). The event
payload is irrelevant — every invocation performs one full sweep of overdue,
un-resolved tickets and auto-escalates them. It is NOT reachable over HTTP.

Configuration arrives through the process environment (TABLE_NAME, and
optionally EVENTS_QUEUE_URL/QUEUE_URL for notification fan-out), populated by
Terraform — nothing is hardcoded here.
"""
import logging
import os

from escalamiento import service

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def lambda_handler(event, context):
    """Run one SLA-breach escalation sweep. Returns the run summary."""
    summary = service.sweep_overdue()
    return {"statusCode": 200, "summary": summary}

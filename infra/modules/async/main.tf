# ===========================================================================
# Async messaging — a standard SQS queue plus a dead-letter queue (DLQ).
#
# Messages the consumer fails to process max_receive_count times are moved to
# the DLQ by the redrive_policy instead of being retried forever or silently
# dropped. The DLQ keeps them longer than the main queue so an operator can
# inspect and replay them. Both names derive from var.queue_name_prefix — no
# hardcoded queue names.
# ===========================================================================

locals {
  module_tags = merge(var.tags, {
    ManagedBy = "Terraform"
    Module    = "async"
  })
}

# Dead-letter queue — declared first so the main queue's redrive_policy can
# reference its ARN. Receives messages that exhaust max_receive_count.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.queue_name_prefix}-events-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds

  tags = merge(local.module_tags, {
    Role = "dead-letter"
  })
}

# Main queue — producers send here, the consumer polls here. The redrive_policy
# wires failed messages to the DLQ after max_receive_count receive attempts.
resource "aws_sqs_queue" "main" {
  name                       = "${var.queue_name_prefix}-events"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(local.module_tags, {
    Role = "main"
  })
}

# Allow only the DLQ's own redrive source (the main queue) to redrive messages
# back out of the DLQ — least privilege on the DLQ redrive permission.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

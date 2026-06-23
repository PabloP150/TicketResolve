locals {
  module_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "iam"
  })

  name_prefix = "${var.project_name}-${var.environment}"

  # All DynamoDB resources the compute roles may touch: the table plus its GSIs.
  dynamodb_resources = concat([var.dynamodb_table_arn], var.dynamodb_gsi_arns)

  dynamodb_read_actions = [
    "dynamodb:GetItem",
    "dynamodb:BatchGetItem",
    "dynamodb:Query",
    "dynamodb:Scan",
    "dynamodb:ConditionCheckItem",
  ]

  dynamodb_write_actions = [
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:BatchWriteItem",
  ]

  dynamodb_rw_actions = concat(local.dynamodb_read_actions, local.dynamodb_write_actions)

  # Per-function CloudWatch log-group ARNs, constructed from names so this
  # module never depends on the compute module (which would create a cycle).
  log_group_arn = {
    api_tickets  = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${var.api_tickets_function_name}:*"
    webhook      = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${var.webhook_function_name}:*"
    escalamiento = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${var.escalamiento_function_name}:*"
    notificacion = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${var.notificacion_function_name}:*"
    reporte      = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${var.reporte_function_name}:*"
  }
}

# Shared assume-role trust for every Lambda execution role.
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Reusable logs statement builder is not possible as a function, so each policy
# document below repeats a scoped logs statement referencing its own log group.

# ===========================================================================
# Role 1 — compute_api  (api-tickets Lambda)
# DynamoDB RW + S3 attachments RW + SQS SendMessage + own logs.
# ===========================================================================
resource "aws_iam_role" "compute_api" {
  name               = "${local.name_prefix}-compute-api"
  description        = "Execution role for the api-tickets Lambda. DynamoDB RW on the table+GSIs, S3 RW on the attachments bucket, SQS SendMessage on the events queue, and writes to its own log group."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "compute_api" {
  statement {
    sid       = "DynamoDBReadWrite"
    effect    = "Allow"
    actions   = local.dynamodb_rw_actions
    resources = local.dynamodb_resources
  }
  statement {
    sid       = "S3AttachmentsObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.attachments_bucket_arn}/*"]
  }
  statement {
    sid       = "S3AttachmentsList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.attachments_bucket_arn]
  }
  statement {
    sid       = "SQSSendEvents"
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }
  statement {
    # POST /api/v1/reports fires the reporte-pdf worker asynchronously
    # (InvocationType=Event) so the heavy scan/render never blocks the request.
    sid       = "InvokeReportWorker"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.reporte_function_arn]
  }
  statement {
    # S3 objects are encrypted with the CMK, so reads need Decrypt and writes
    # need GenerateDataKey on that one key.
    sid       = "UseCMKForS3"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn.api_tickets]
  }
}

resource "aws_iam_policy" "compute_api" {
  name        = "${local.name_prefix}-compute-api"
  description = "Least-privilege policy for the api-tickets Lambda."
  policy      = data.aws_iam_policy_document.compute_api.json
  tags        = local.module_tags
}

resource "aws_iam_role_policy_attachment" "compute_api" {
  role       = aws_iam_role.compute_api.name
  policy_arn = aws_iam_policy.compute_api.arn
}

# ===========================================================================
# Role 2 — compute_webhook  (webhook-ingesta Lambda)  DynamoDB RW + logs.
# ===========================================================================
resource "aws_iam_role" "compute_webhook" {
  name               = "${local.name_prefix}-compute-webhook"
  description        = "Execution role for the webhook-ingesta Lambda. DynamoDB RW on the table+GSIs and writes to its own log group."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "compute_webhook" {
  statement {
    sid       = "DynamoDBReadWrite"
    effect    = "Allow"
    actions   = local.dynamodb_rw_actions
    resources = local.dynamodb_resources
  }
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn.webhook]
  }
}

resource "aws_iam_policy" "compute_webhook" {
  name        = "${local.name_prefix}-compute-webhook"
  description = "Least-privilege policy for the webhook-ingesta Lambda."
  policy      = data.aws_iam_policy_document.compute_webhook.json
  tags        = local.module_tags
}

resource "aws_iam_role_policy_attachment" "compute_webhook" {
  role       = aws_iam_role.compute_webhook.name
  policy_arn = aws_iam_policy.compute_webhook.arn
}

# ===========================================================================
# Role 3 — compute_escalamiento  (escalamiento Lambda)  DynamoDB RW + logs.
# ===========================================================================
resource "aws_iam_role" "compute_escalamiento" {
  name               = "${local.name_prefix}-compute-escalamiento"
  description        = "Execution role for the escalamiento Lambda. DynamoDB RW on the table+GSIs, SQS SendMessage on the events queue (escalation notifications), and writes to its own log group."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "compute_escalamiento" {
  statement {
    sid       = "DynamoDBReadWrite"
    effect    = "Allow"
    actions   = local.dynamodb_rw_actions
    resources = local.dynamodb_resources
  }
  statement {
    # On auto-escalation the worker enqueues a notification event for the
    # notificacion consumer to fan out (US-04 -> US-05).
    sid       = "SQSSendEvents"
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn.escalamiento]
  }
}

resource "aws_iam_policy" "compute_escalamiento" {
  name        = "${local.name_prefix}-compute-escalamiento"
  description = "Least-privilege policy for the escalamiento Lambda."
  policy      = data.aws_iam_policy_document.compute_escalamiento.json
  tags        = local.module_tags
}

resource "aws_iam_role_policy_attachment" "compute_escalamiento" {
  role       = aws_iam_role.compute_escalamiento.name
  policy_arn = aws_iam_policy.compute_escalamiento.arn
}

# ===========================================================================
# Role 4 — async_consumer  (notificacion Lambda)
# SQS consume + S3 write + Secrets read + KMS decrypt + own logs.
# ===========================================================================
resource "aws_iam_role" "async_consumer" {
  name               = "${local.name_prefix}-async-consumer"
  description        = "Execution role for the notificacion async consumer. Consumes the events queue, publishes notifications to the SNS topic, and writes to its own log group. (S3/secret/KMS grants retained from Delivery 5.)"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "async_consumer" {
  statement {
    sid       = "SQSConsumeEvents"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }
  statement {
    # Fan domain events out to subscribers (email) via the notifications topic.
    sid       = "SNSPublishNotifications"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.notifications_topic_arn]
  }
  statement {
    sid       = "S3WriteEventObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.attachments_bucket_arn}/*"]
  }
  statement {
    sid       = "ReadDBPasswordSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arn]
  }
  statement {
    # Decrypt the secret (via Secrets Manager) and read/write CMK-encrypted S3
    # objects (GetObject needs Decrypt, PutObject needs GenerateDataKey).
    sid       = "UseCMK"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn.notificacion]
  }
}

resource "aws_iam_policy" "async_consumer" {
  name        = "${local.name_prefix}-async-consumer"
  description = "Least-privilege policy for the notificacion async consumer."
  policy      = data.aws_iam_policy_document.async_consumer.json
  tags        = local.module_tags
}

resource "aws_iam_role_policy_attachment" "async_consumer" {
  role       = aws_iam_role.async_consumer.name
  policy_arn = aws_iam_policy.async_consumer.arn
}

# ===========================================================================
# Role 5 — compute_reporte  (reporte-pdf Lambda)
# DynamoDB read-only + S3 reports write + own logs.
# ===========================================================================
resource "aws_iam_role" "compute_reporte" {
  name               = "${local.name_prefix}-compute-reporte"
  description        = "Execution role for the reporte-pdf Lambda. DynamoDB read-only on the table+GSIs, s3:PutObject on the reports bucket, SQS SendMessage on the events queue (report-ready notification), and writes to its own log group."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "compute_reporte" {
  statement {
    sid       = "DynamoDBReadOnly"
    effect    = "Allow"
    actions   = local.dynamodb_read_actions
    resources = local.dynamodb_resources
  }
  statement {
    sid       = "S3ReportsWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.reports_bucket_arn}/*"]
  }
  statement {
    # After generating a report the worker enqueues a REPORT_READY event so the
    # notificacion consumer can email the download link (US-06).
    sid       = "SQSSendEvents"
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }
  statement {
    # Writing CMK-encrypted objects to the reports bucket needs GenerateDataKey.
    sid       = "UseCMKForS3"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn.reporte]
  }
}

resource "aws_iam_policy" "compute_reporte" {
  name        = "${local.name_prefix}-compute-reporte"
  description = "Least-privilege policy for the reporte-pdf Lambda."
  policy      = data.aws_iam_policy_document.compute_reporte.json
  tags        = local.module_tags
}

resource "aws_iam_role_policy_attachment" "compute_reporte" {
  role       = aws_iam_role.compute_reporte.name
  policy_arn = aws_iam_policy.compute_reporte.arn
}

# ===========================================================================
# Role 6 — scheduler  (EventBridge Scheduler -> escalamiento)
# May ONLY lambda:InvokeFunction the single escalamiento ARN.
# ===========================================================================
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    sid     = "SchedulerAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name_prefix}-scheduler-invoke"
  description        = "EventBridge Scheduler role for the SLA sweep. May only lambda:InvokeFunction the escalamiento Lambda - nothing else."
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "InvokeEscalamiento"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.escalamiento_function_arn]
  }
}

resource "aws_iam_policy" "scheduler" {
  name        = "${local.name_prefix}-scheduler-invoke"
  description = "Least-privilege policy: invoke only the escalamiento Lambda."
  policy      = data.aws_iam_policy_document.scheduler.json
  tags        = local.module_tags
}

resource "aws_iam_role_policy_attachment" "scheduler" {
  role       = aws_iam_role.scheduler.name
  policy_arn = aws_iam_policy.scheduler.arn
}

# NOTE (Delivery 5): the GitHub Actions OIDC provider and the CI runner role
# used to live here, but they are CI prerequisites that must survive a
# `terraform destroy` on this workspace — otherwise the next clean-state CD run
# could not authenticate. They were moved to infra/bootstrap/ (alongside the
# state backend and the DNS zone). This module now defines only the per-service
# execution roles.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  region         = data.aws_region.current.name
  log_group_name = "/aws/lambda/${var.function_name}"
  log_group_arn  = "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"

  module_tags = merge(var.tags, {
    Environment  = var.environment
    ManagedBy    = "Terraform"
    Module       = "compute"
    FunctionName = var.function_name
  })
}

# Packaging: when var.source_dir is set the module zips that directory as the
# real handler (Delivery 3 E2E endpoints). Otherwise it bundles an inline
# placeholder that returns a static 200 — enough to PROVISION functions whose
# business logic lands in a later delivery.
data "archive_file" "placeholder" {
  count       = var.source_dir == null ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/build/${var.function_name}.zip"

  source {
    filename = "lambda_function.py"
    content  = <<-PYTHON
      """Placeholder handler for ${var.function_name}.
      Returns a static 200 response. Real business logic lands in a later delivery.
      """

      def lambda_handler(event, context):
          return {
              "statusCode": 200,
              "body": '{"status":"ok","function":"${var.function_name}"}',
              "headers": {"Content-Type": "application/json"},
          }
    PYTHON
  }
}

data "archive_file" "from_source" {
  count       = var.source_dir == null ? 0 : 1
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/build/${var.function_name}.zip"
}

locals {
  archive_path = var.source_dir == null ? data.archive_file.placeholder[0].output_path : data.archive_file.from_source[0].output_path
  archive_hash = var.source_dir == null ? data.archive_file.placeholder[0].output_base64sha256 : data.archive_file.from_source[0].output_base64sha256
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_in_days
  tags              = local.module_tags
}

data "aws_iam_policy_document" "assume_role" {
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

resource "aws_iam_role" "execution" {
  name               = "${var.function_name}-exec"
  description        = "Execution role for the ${var.function_name} Lambda. Scoped to its own CloudWatch log group plus the service-specific statements wired from the root module."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "execution" {
  # Minimum permissions needed for the function to write its own logs.
  # Resource is scoped to this Lambda's log group ARN — no wildcards on Resource or Action.
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${local.log_group_arn}:*",
    ]
  }

  # Service-specific statements appended by the caller (e.g. DynamoDB GetItem, S3 PutObject).
  dynamic "statement" {
    for_each = var.additional_iam_statements
    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.function_name}-exec-policy"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  role          = aws_iam_role.execution.arn
  runtime       = var.runtime
  handler       = var.handler
  memory_size   = var.memory_size
  timeout       = var.timeout

  reserved_concurrent_executions = var.reserved_concurrent_executions

  filename         = local.archive_path
  source_code_hash = local.archive_hash

  environment {
    variables = merge(var.environment_variables, {
      ENV           = var.environment
      FUNCTION_NAME = var.function_name
    })
  }

  tags = local.module_tags

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy.execution,
  ]
}

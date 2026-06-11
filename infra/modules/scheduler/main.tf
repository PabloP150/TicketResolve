# ===========================================================================
# Scheduled job — an EventBridge Scheduler schedule that invokes a Lambda on a
# fixed cadence. Used for the TicketResolve SLA sweep: a periodic run of the
# escalamiento Lambda that scans for open tickets past their SLA. This target
# is DISTINCT from the async consumer (notificacion) per the Delivery 4 spec.
#
# The schedule has its own IAM role whose only permission is lambda:InvokeFunction
# on the single target function ARN. That is narrower than the target Lambda's
# own execution role (which can read/write DynamoDB): the scheduler may only
# *invoke*, never touch data.
# ===========================================================================

locals {
  module_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "scheduler"
  })
}

data "aws_iam_policy_document" "assume_role" {
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
  name               = "${var.schedule_name}-invoke"
  description        = "Dedicated EventBridge Scheduler role for ${var.schedule_name}. Allows lambda:InvokeFunction on exactly ${var.target_lambda_name} and nothing else."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = local.module_tags
}

# Least privilege: invoke only the one target function. No wildcard ARN.
data "aws_iam_policy_document" "invoke" {
  statement {
    sid       = "InvokeTargetLambda"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.target_lambda_arn]
  }
}

resource "aws_iam_role_policy" "invoke" {
  name   = "${var.schedule_name}-invoke-policy"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.invoke.json
}

resource "aws_scheduler_schedule" "this" {
  name       = var.schedule_name
  group_name = "default"

  flexible_time_window {
    mode                      = var.flexible_time_window_minutes == 0 ? "OFF" : "FLEXIBLE"
    maximum_window_in_minutes = var.flexible_time_window_minutes == 0 ? null : var.flexible_time_window_minutes
  }

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.scheduler_timezone

  target {
    arn      = var.target_lambda_arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

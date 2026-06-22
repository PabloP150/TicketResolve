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

# NOTE (Delivery 5): the scheduler's invoke role is now defined centrally in
# infra/modules/iam/ (lambda:InvokeFunction scoped to the escalamiento ARN) and
# injected via var.scheduler_role_arn. This module no longer creates the role.

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
    role_arn = var.scheduler_role_arn
  }
}

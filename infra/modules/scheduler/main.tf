# ===========================================================================
# Scheduled job — an EventBridge Scheduler schedule that invokes a Lambda on a
# fixed cadence. Used for the TicketResolve SLA sweep: a periodic run of the
# escalamiento Lambda that scans for open tickets past their SLA. This target
# is DISTINCT from the async consumer (notificacion) per the Delivery 4 spec.
#
# The schedule's IAM role (lambda:InvokeFunction scoped to the single target
# function ARN — narrower than the target Lambda's own execution role) is now
# defined centrally in infra/modules/iam/ and injected via var.scheduler_role_arn
# (Delivery 5). This module only creates the schedule itself; aws_scheduler_schedule
# does not take free-form tags, so this module declares none.
# ===========================================================================

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

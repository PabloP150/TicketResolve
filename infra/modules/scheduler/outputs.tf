output "schedule_arn" {
  description = "ARN of the EventBridge Scheduler schedule. Useful for CLI introspection (aws scheduler get-schedule) in evidence steps."
  value       = aws_scheduler_schedule.this.arn
}

output "schedule_name" {
  description = "Name of the EventBridge Scheduler schedule."
  value       = aws_scheduler_schedule.this.name
}

output "scheduler_role_arn" {
  description = "ARN of the IAM role the scheduler assumes to invoke the target Lambda (defined in infra/modules/iam/, injected via var.scheduler_role_arn)."
  value       = var.scheduler_role_arn
}

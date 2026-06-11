output "schedule_arn" {
  description = "ARN of the EventBridge Scheduler schedule. Useful for CLI introspection (aws scheduler get-schedule) in evidence steps."
  value       = aws_scheduler_schedule.this.arn
}

output "schedule_name" {
  description = "Name of the EventBridge Scheduler schedule."
  value       = aws_scheduler_schedule.this.name
}

output "scheduler_role_arn" {
  description = "ARN of the dedicated IAM role the scheduler assumes to invoke the target Lambda. Scoped to lambda:InvokeFunction on the single target ARN."
  value       = aws_iam_role.scheduler.arn
}

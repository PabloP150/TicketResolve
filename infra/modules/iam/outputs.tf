# --- Role ARNs (consumed by the compute / scheduler module calls) -----------
output "compute_api_role_arn" {
  description = "ARN of the api-tickets execution role. Wired into the lambda_api_tickets module call as execution_role_arn."
  value       = aws_iam_role.compute_api.arn
}

output "compute_webhook_role_arn" {
  description = "ARN of the webhook-ingesta execution role."
  value       = aws_iam_role.compute_webhook.arn
}

output "compute_escalamiento_role_arn" {
  description = "ARN of the escalamiento execution role."
  value       = aws_iam_role.compute_escalamiento.arn
}

output "async_consumer_role_arn" {
  description = "ARN of the notificacion async-consumer execution role."
  value       = aws_iam_role.async_consumer.arn
}

output "compute_reporte_role_arn" {
  description = "ARN of the reporte-pdf execution role."
  value       = aws_iam_role.compute_reporte.arn
}

output "scheduler_role_arn" {
  description = "ARN of the EventBridge Scheduler role. Wired into the sla_sweep_scheduler module call as scheduler_role_arn."
  value       = aws_iam_role.scheduler.arn
}

# --- Policy ARNs (rubric A: expose each policy ARN) -------------------------
output "compute_api_policy_arn" {
  description = "ARN of the api-tickets managed policy."
  value       = aws_iam_policy.compute_api.arn
}

output "compute_webhook_policy_arn" {
  description = "ARN of the webhook-ingesta managed policy."
  value       = aws_iam_policy.compute_webhook.arn
}

output "compute_escalamiento_policy_arn" {
  description = "ARN of the escalamiento managed policy."
  value       = aws_iam_policy.compute_escalamiento.arn
}

output "async_consumer_policy_arn" {
  description = "ARN of the async-consumer managed policy."
  value       = aws_iam_policy.async_consumer.arn
}

output "compute_reporte_policy_arn" {
  description = "ARN of the reporte-pdf managed policy."
  value       = aws_iam_policy.compute_reporte.arn
}

output "scheduler_policy_arn" {
  description = "ARN of the scheduler invoke managed policy."
  value       = aws_iam_policy.scheduler.arn
}

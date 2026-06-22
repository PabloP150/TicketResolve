output "log_group_names" {
  description = "Map of service key -> CloudWatch log group name created for each Lambda."
  value       = { for k, lg in aws_cloudwatch_log_group.lambda : k => lg.name }
}

output "log_group_arns" {
  description = "Map of service key -> CloudWatch log group ARN. Surfaced for the observability evidence file."
  value       = { for k, lg in aws_cloudwatch_log_group.lambda : k => lg.arn }
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic that receives alarm and budget notifications."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_arns" {
  description = "ARNs of every CloudWatch alarm (per-Lambda errors, API Gateway 5xx, DLQ depth). Surfaced for the observability evidence file."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.arn],
    [aws_cloudwatch_metric_alarm.apigw_5xx.arn],
    [aws_cloudwatch_metric_alarm.dlq_depth.arn],
  )
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "budget_name" {
  description = "Name of the monthly cost budget."
  value       = aws_budgets_budget.monthly.name
}

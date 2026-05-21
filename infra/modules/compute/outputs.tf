output "function_arn" {
  description = "ARN of the deployed Lambda function. Required by API Gateway integrations, EventBridge targets, and SQS triggers."
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Name of the deployed Lambda function. Surfaced as a root output for evidence (aws lambda get-function --function-name)."
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = "Lambda invoke ARN. This is the value API Gateway needs in its integration_uri field, distinct from the function ARN."
  value       = aws_lambda_function.this.invoke_arn
}

output "role_arn" {
  description = "ARN of the Lambda execution role. Useful for attaching additional managed policies from the root if ever required."
  value       = aws_iam_role.execution.arn
}

output "role_name" {
  description = "Name of the Lambda execution role."
  value       = aws_iam_role.execution.name
}

output "log_group_name" {
  description = "Name of the Lambda's CloudWatch log group. Useful for CloudWatch Insights queries and alarm targets in Delivery 5."
  value       = aws_cloudwatch_log_group.this.name
}

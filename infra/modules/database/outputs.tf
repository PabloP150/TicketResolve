output "table_arn" {
  description = "ARN of the DynamoDB table. Consumed by IAM policies that grant Lambdas dynamodb:* actions scoped to this table."
  value       = aws_dynamodb_table.this.arn
}

output "table_name" {
  description = "Name of the DynamoDB table. Injected into Lambda environment variables so the application code knows which table to query."
  value       = aws_dynamodb_table.this.name
}

output "gsi1_arn" {
  description = "ARN of GSI1 (engineer dashboard index). Required when scoping IAM permissions to specific indexes."
  value       = "${aws_dynamodb_table.this.arn}/index/GSI1"
}

output "gsi2_arn" {
  description = "ARN of GSI2 (event-hash deduplication index). Required when scoping IAM permissions to specific indexes."
  value       = "${aws_dynamodb_table.this.arn}/index/GSI2"
}

output "stream_arn" {
  description = "ARN of the DynamoDB stream. Will be consumed by an audit Lambda in Delivery 4."
  value       = aws_dynamodb_table.this.stream_arn
}

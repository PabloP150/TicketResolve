output "state_bucket_name" {
  description = "Name of the S3 bucket that stores the main workspace's Terraform state file. Hardcode this value into infra/backend.tf."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking. Hardcode this value into infra/backend.tf."
  value       = aws_dynamodb_table.lock.name
}

output "region" {
  description = "AWS region where the state bucket and lock table were created. Hardcode this value into infra/backend.tf."
  value       = var.region
}

output "state_bucket_arn" {
  description = "ARN of the state bucket. Useful for cross-account IAM policy references in later deliveries."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_arn" {
  description = "ARN of the lock table. Useful for cross-account IAM policy references in later deliveries."
  value       = aws_dynamodb_table.lock.arn
}

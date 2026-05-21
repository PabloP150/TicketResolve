output "bucket_arn" {
  description = "ARN of the provisioned S3 bucket. Consumed by IAM policies that grant Lambdas access to read/write objects in this bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_name" {
  description = "Name of the provisioned S3 bucket. Consumed by application code (via Lambda env vars) to construct s3:// paths."
  value       = aws_s3_bucket.this.id
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the bucket. Useful for presigned URL construction and as an explicit endpoint for the AWS SDK."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

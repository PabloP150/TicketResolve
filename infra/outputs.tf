output "bootstrap_bucket_arn" {
  description = "ARN of the bootstrap S3 bucket. Downstream modules in later deliveries (e.g. storage for application artifacts, log targets) will reference this ARN through remote state."
  value       = aws_s3_bucket.bootstrap.arn
}

output "bootstrap_bucket_name" {
  description = "Resolved name of the bootstrap S3 bucket. Pipeline steps and IAM policies generated in later deliveries consume this value to scope permissions."
  value       = aws_s3_bucket.bootstrap.id
}

output "workspace_region" {
  description = "AWS region effectively used by this workspace. Surfaced as an output so CI steps and downstream modules don't have to re-derive it from var.region."
  value       = var.region
}

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

# --- Delegated DNS zone (Delivery 5, Deliverable D) -------------------------
output "dns_zone_id" {
  description = "Route53 hosted zone id for the delegated subdomain. Looked up by the main workspace via a data source for ACM validation and the custom-domain alias records."
  value       = aws_route53_zone.delegated.zone_id
}

output "dns_zone_name" {
  description = "The delegated subdomain name (e.g. grupo7.oyd.solid.com.gt)."
  value       = aws_route53_zone.delegated.name
}

output "dns_name_servers" {
  description = "The four name servers for the delegated zone. SEND THESE (plus the subdomain) to the instructor so they can delegate the subdomain from the parent oyd.solid.com.gt zone."
  value       = aws_route53_zone.delegated.name_servers
}

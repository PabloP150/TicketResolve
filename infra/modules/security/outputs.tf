output "web_sg_id" {
  description = "ID of the web-tier security group (HTTP/HTTPS from the Internet, egress to the app tier)."
  value       = aws_security_group.web.id
}

output "app_sg_id" {
  description = "ID of the app-tier security group. Attach this to the Lambda ENIs when the compute layer is placed in the VPC."
  value       = aws_security_group.app.id
}

output "db_sg_id" {
  description = "ID of the db-tier security group. Attach this to the future RDS/ElastiCache layer in the private-data subnets."
  value       = aws_security_group.db.id
}

output "public_nacl_id" {
  description = "ID of the public-subnet network ACL."
  value       = aws_network_acl.public.id
}

output "private_nacl_id" {
  description = "ID of the private-subnet network ACL."
  value       = aws_network_acl.private.id
}

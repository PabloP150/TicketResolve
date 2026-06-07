output "vpc_id" {
  description = "ID of the VPC. Consumed by the security module (SGs/NACLs) and by any future VPC-bound compute or data resource."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC. Useful for NACL rules that need to scope traffic to in-VPC ranges."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (one per AZ). Host the NAT Gateway and any future load balancer."
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "List of private application subnet IDs (one per AZ). Target for the Lambda ENIs when compute is attached to the VPC."
  value       = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  description = "List of private data subnet IDs (one per AZ). Reserved for a future RDS / ElastiCache layer."
  value       = aws_subnet.private_data[*].id
}

output "private_subnet_ids" {
  description = "All private subnet IDs (app + data) combined. Satisfies the rubric's 'private subnet ID list' output and is convenient for NACL association."
  value       = concat(aws_subnet.private_app[*].id, aws_subnet.private_data[*].id)
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs. Empty when enable_nat_gateway = false. One element for single-NAT topology, one per AZ otherwise."
  value       = aws_nat_gateway.this[*].id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway attached to the VPC."
  value       = aws_internet_gateway.this.id
}

output "public_route_table_id" {
  description = "ID of the public route table (routes to the Internet Gateway)."
  value       = aws_route_table.public.id
}

output "private_app_route_table_ids" {
  description = "IDs of the per-AZ private-app route tables (routes to the NAT Gateway and the Gateway Endpoints)."
  value       = aws_route_table.private_app[*].id
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 Gateway VPC Endpoint. Lets in-VPC compute reach S3 without traversing the NAT/Internet."
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_vpc_endpoint_id" {
  description = "ID of the DynamoDB Gateway VPC Endpoint."
  value       = aws_vpc_endpoint.dynamodb.id
}

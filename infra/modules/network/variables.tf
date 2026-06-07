variable "name_prefix" {
  description = "Prefix applied to every network resource name (e.g. ticketresolve-dev). Derived in the root module from app_name + environment — never hardcoded here."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev/prod). Surfaced in tags so resources can be filtered per environment."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be a private RFC 1918 range large enough for the three-tier subnet layout across the configured AZs."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block (e.g. 10.20.0.0/16)."
  }
}

variable "availability_zones" {
  description = "List of availability zones to spread the subnets across. Length drives how many subnets of each tier are created; the *_subnet_cidrs lists must have the same length."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required so each subnet tier has two distinct AZs (rubric requirement)."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, one per availability zone (same order as availability_zones). Public subnets host the NAT Gateway and any future ALB."
  type        = list(string)
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for the private application subnets, one per availability zone. These host the Lambda ENIs when the compute layer is attached to the VPC."
  type        = list(string)
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for the private data subnets, one per availability zone. Reserved (kept empty) for a future RDS / ElastiCache layer; never share a subnet between the app and data tiers."
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Whether to provision the NAT Gateway(s) and the private-app default route to them. Required for full Delivery-3 credit; can be turned off to reach $0 cost when the compute layer runs outside the VPC."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "NAT topology toggle. true = one shared NAT Gateway in the first public subnet (cheaper, single-AZ risk). false = one NAT Gateway per AZ (full HA, higher cost)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto every resource created by this module."
  type        = map(string)
  default     = {}
}

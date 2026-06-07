variable "name_prefix" {
  description = "Prefix applied to every security resource name (e.g. ticketresolve-dev). Derived in the root from app_name + environment."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev/prod). Surfaced in tags."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC the security groups and NACLs belong to. Wired from the network module output."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs the public NACL is associated with. Wired from the network module."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (app + data) the private NACL is associated with. Wired from the network module."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. Used by the private NACL to allow intra-VPC traffic."
  type        = string
}

variable "web_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the web tier on the HTTP/HTTPS ports. Defaults to the public Internet."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "http_port" {
  description = "HTTP port allowed inbound on the web security group."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "HTTPS port allowed inbound on the web security group."
  type        = number
  default     = 443
}

variable "app_port" {
  description = "Application-tier port. web-sg may egress to app-sg on this port and app-sg accepts inbound from web-sg on it. For this serverless stack it represents the HTTPS port the application layer would serve on."
  type        = number
  default     = 443
}

variable "db_port" {
  description = "Database-tier port. app-sg egresses to db-sg on this port and db-sg accepts inbound from app-sg on it. Defaults to PostgreSQL (the future RDS engine reserved for the private-data tier)."
  type        = number
  default     = 5432
}

variable "tcp_protocol" {
  description = "Protocol value used by the security group and NACL rules."
  type        = string
  default     = "tcp"
}

variable "ephemeral_port_from" {
  description = "Start of the ephemeral port range used by stateless NACL rules to allow return traffic."
  type        = number
  default     = 1024
}

variable "ephemeral_port_to" {
  description = "End of the ephemeral port range used by stateless NACL rules to allow return traffic."
  type        = number
  default     = 65535
}

variable "tags" {
  description = "Additional tags merged onto every resource created by this module."
  type        = map(string)
  default     = {}
}

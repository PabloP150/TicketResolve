variable "environment" {
  description = "Deployment environment for the workspace. Drives naming, tagging and per-environment overrides. Expected values: dev, prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either 'dev' or 'prod'."
  }
}

variable "app_name" {
  description = "Short application name used as a prefix for resource names and as the Project tag. Lowercase alphanumeric and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,32}$", var.app_name))
    error_message = "app_name must be 2-32 chars of lowercase letters, digits or hyphens."
  }
}

variable "region" {
  description = "AWS region where all resources in this workspace will be created."
  type        = string
  default     = "us-east-1"
}

variable "architecture" {
  description = "Default CPU architecture for future compute workloads (Lambda, ECS tasks, EC2). Exposed as a tag on every resource so future compute modules can read it consistently."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be either 'x86_64' or 'arm64'."
  }
}

variable "lambda_memory_default" {
  description = "Default memory (MB) for Lambda functions that do not specify their own. Functions with heavier work (reporte-pdf) override this per-call."
  type        = number
  default     = 256
}

variable "lambda_timeout_default" {
  description = "Default timeout (seconds) for Lambda functions that do not specify their own."
  type        = number
  default     = 10
}

# --- Networking (Delivery 3) -------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the project VPC. Private RFC 1918 range with room for the three-tier subnet layout across two AZs."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones the subnets are spread across. Length must match the *_subnet_cidrs lists."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, one per AZ (NAT Gateway and future ALB)."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for the private application subnets, one per AZ (Lambda ENIs when attached to the VPC)."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for the private data subnets, one per AZ (reserved for a future RDS / ElastiCache layer)."
  type        = list(string)
  default     = ["10.20.20.0/24", "10.20.21.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to provision the NAT Gateway(s) and the private-app default route. Required for full Delivery-3 credit."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "true = one shared NAT Gateway (cheaper, single-AZ risk). false = one NAT per AZ (full HA, higher cost)."
  type        = bool
  default     = true
}

# --- Network security (Delivery 3) ------------------------------------------

variable "web_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the web tier on HTTP/HTTPS."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "http_port" {
  description = "HTTP port allowed inbound on the web tier and the public NACL."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "HTTPS port allowed inbound on the web tier and the public NACL."
  type        = number
  default     = 443
}

variable "app_port" {
  description = "Application-tier port for the web -> app security-group rules."
  type        = number
  default     = 443
}

variable "db_port" {
  description = "Database-tier port for the app -> db security-group rules (PostgreSQL default for the reserved data layer)."
  type        = number
  default     = 5432
}

# --- Ingress (Delivery 3) ---------------------------------------------------

variable "health_check_path" {
  description = "Path exposed as the ingress health/readiness check (routed GET to the api-tickets Lambda)."
  type        = string
  default     = "/"
}

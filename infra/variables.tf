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

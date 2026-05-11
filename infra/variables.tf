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

variable "bucket_name" {
  description = "Globally unique base name for the bootstrap S3 bucket. The full bucket name is composed as '<bucket_name>-<environment>' (e.g. 'ticketresolve-bucket-dev'). Must satisfy S3 naming rules."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-42 chars, lowercase alphanumerics and hyphens, and cannot start or end with a hyphen."
  }
}

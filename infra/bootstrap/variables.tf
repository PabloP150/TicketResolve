variable "region" {
  description = "AWS region where the state bucket and lock table live."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project identifier used as the prefix for the state bucket and the lock table names."
  type        = string
  default     = "ticketresolve"
}

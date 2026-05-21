variable "table_name" {
  description = "Full DynamoDB table name. Single-table design — all TicketResolve entities live in this one table differentiated by PK/SK prefixes."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev/prod). Used in tags."
  type        = string
}

variable "billing_mode" {
  description = "DynamoDB billing mode. PAY_PER_REQUEST is the right choice for the TicketResolve workload (bursty webhook ingest, unpredictable read patterns) and qualifies for the free tier."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "ttl_attribute_name" {
  description = "Name of the attribute used by DynamoDB TTL to automatically expire items (e.g. deduplication windows). The attribute itself is set per-item by application code; the table just needs to declare it."
  type        = string
  default     = "ttl"
}

variable "tags" {
  description = "Additional tags to merge on the table. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

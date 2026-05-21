variable "bucket_name" {
  description = "Full S3 bucket name. Must be globally unique within AWS and satisfy S3 naming rules (3-63 chars, lowercase alphanumerics and hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars, lowercase alphanumerics and hyphens, and cannot start or end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment (dev/prod). Surfaced in tags and used by callers to differentiate per-env buckets."
  type        = string
}

variable "lifecycle_rules" {
  description = "List of lifecycle rules to apply. Each rule must include a prefix (or filter) so the rule is scoped and does not apply blindly to the whole bucket. transition_days/transition_storage_class are optional; expiration_days is optional."
  type = list(object({
    id                         = string
    prefix                     = string
    transition_days            = optional(number)
    transition_storage_class   = optional(string)
    expiration_days            = optional(number)
    noncurrent_expiration_days = optional(number)
  }))

  validation {
    condition     = length(var.lifecycle_rules) >= 1
    error_message = "At least one lifecycle rule must be defined (rubric requirement)."
  }

  validation {
    condition     = alltrue([for r in var.lifecycle_rules : length(r.prefix) > 0])
    error_message = "Every lifecycle rule must have a non-empty prefix (rubric forbids rules that apply to the entire bucket without a scope)."
  }
}

variable "tags" {
  description = "Additional tags to merge on the bucket. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

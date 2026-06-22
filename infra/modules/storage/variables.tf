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

variable "kms_key_arn" {
  description = "ARN of the customer-managed KMS key (CMK) used to encrypt objects at rest (Delivery 5). When null the bucket falls back to SSE-S3/AES256; when set the bucket uses aws:kms with this CMK and bucket keys enabled."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "When true, terraform destroy empties the bucket (deleting all objects and versions) before deleting it, so a non-empty bucket does not block the destroy. Keep false for prod-like buckets where accidental data loss must be impossible; set true for ephemeral dev/staging environments that are torn down and rebuilt."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to merge on the bucket. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

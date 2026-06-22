variable "environment" {
  description = "Deployment environment (dev/staging/prod). Surfaced in tags and in the CMK alias / secret name so resources never collide across environments."
  type        = string
}

variable "project_name" {
  description = "Application/project name (e.g. ticketresolve). Used as the prefix of the KMS alias and the Secrets Manager secret name."
  type        = string
}

variable "region" {
  description = "AWS region the CMK lives in. Used to build the kms:ViaService condition values (s3.<region>.amazonaws.com, etc.) that scope which services may use the key."
  type        = string
}

variable "account_id" {
  description = "AWS account id that owns the CMK. Used as the root ARN base in the key policy and in the kms:CallerAccount condition so the key can only be used from within this account."
  type        = string
}

variable "db_password" {
  description = "Sensitive database password to store in Secrets Manager. Supplied from a sensitive Terraform variable (TF_VAR or sensitive default) — never hardcoded in a committed .tfvars file."
  type        = string
  sensitive   = true
}

variable "key_admin_principal_arns" {
  description = "IAM principal ARNs (the human deployer and the CI runner role) allowed to ADMINISTER the CMK. Scoped via an aws:PrincipalArn condition on the root principal so the key policy is never open to the whole account without condition."
  type        = list(string)
}

variable "alias_name" {
  description = "Friendly KMS alias (without the 'alias/' prefix). Defaults to <project>-<environment> when null."
  type        = string
  default     = null
}

variable "deletion_window_in_days" {
  description = "Waiting period before AWS permanently deletes the CMK after a destroy. 7 is the minimum and keeps ephemeral dev/staging teardown fast while still allowing recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30 (AWS KMS limits)."
  }
}

variable "enable_key_rotation" {
  description = "Whether AWS automatically rotates the CMK's backing key material yearly. Enabled by default as a security best practice."
  type        = bool
  default     = true
}

variable "secret_recovery_window_days" {
  description = "Recovery window before a deleted secret is permanently removed. 0 forces immediate deletion so ephemeral dev/staging environments can be destroyed and recreated with the same secret name without a 'scheduled for deletion' conflict."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Additional tags merged onto the CMK and the secret. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

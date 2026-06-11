variable "schedule_name" {
  description = "Name of the EventBridge Scheduler schedule. Derived in the root from app_name + environment so it is unique per environment."
  type        = string
}

variable "schedule_expression" {
  description = "When the schedule fires. A rate expression (e.g. 'rate(1 day)') or a cron expression (e.g. 'cron(0 6 * * ? *)'). No cron string is hardcoded in the module — the caller supplies it."
  type        = string
}

variable "scheduler_timezone" {
  description = "IANA time zone the schedule_expression is evaluated in (e.g. 'America/Guatemala'). Makes cron expressions deterministic regardless of the AWS account's default."
  type        = string
}

variable "target_lambda_arn" {
  description = "ARN of the Lambda the schedule invokes. The dedicated scheduler role grants lambda:InvokeFunction on exactly this ARN — no wildcard."
  type        = string
}

variable "target_lambda_name" {
  description = "Name of the target Lambda. Used only for tagging/identification of the schedule; invocation is authorized via target_lambda_arn."
  type        = string
}

variable "flexible_time_window_minutes" {
  description = "Width, in minutes, of the flexible time window in which EventBridge Scheduler may invoke the target. 0 disables flexibility (invoke exactly at the schedule time)."
  type        = number
  default     = 0

  validation {
    condition     = var.flexible_time_window_minutes >= 0 && var.flexible_time_window_minutes <= 1440
    error_message = "flexible_time_window_minutes must be between 0 and 1440 (24 hours)."
  }
}

variable "environment" {
  description = "Deployment environment (dev/staging/prod). Surfaced in tags."
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto the IAM role created by this module (the schedule resource itself does not take free-form tags)."
  type        = map(string)
  default     = {}
}

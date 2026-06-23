variable "environment" {
  description = "Deployment environment (dev/staging/prod). Used as a prefix on log group and resource names so observability never collides across environments."
  type        = string
}

variable "project_name" {
  description = "Application/project name (e.g. ticketresolve). Prefix for the SNS topic, dashboard and budget names."
  type        = string
}

variable "region" {
  description = "AWS region. Used by the dashboard widgets so metrics render in the right region."
  type        = string
}

variable "lambda_function_names" {
  description = "Map of logical service key -> Lambda function name. Drives one CloudWatch log group per function and the per-function error alarms."
  type        = map(string)
}

variable "log_retention_days" {
  description = "Retention, in days, for every Lambda CloudWatch log group. A single knob keeps log storage cost predictable across all functions."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts (1,3,5,7,14,30,...,3653)."
  }
}

variable "api_id" {
  description = "Id of the API Gateway v2 HTTP API. Used as the ApiId dimension for the request-count widget and the 5xx error alarm."
  type        = string
}

variable "queue_name" {
  description = "Name of the main SQS events queue. Used in the dashboard for queue-depth visibility."
  type        = string
}

variable "dlq_name" {
  description = "Name of the dead-letter queue. The DLQ-depth alarm fires when messages start landing in it (a poison-message / processing-failure signal)."
  type        = string
}

variable "notification_email" {
  description = "Email address subscribed to the SNS alarm topic. AWS sends a confirmation email that must be accepted before notifications are delivered."
  type        = string
}

# --- Alarm tuning (all thresholds are variables, no magic numbers) ----------
variable "lambda_error_threshold" {
  description = "Number of Lambda Errors within one evaluation period that trips the per-function error alarm. 1 means 'tell me about any error' — appropriate for a low-traffic academic workload where every error is worth seeing."
  type        = number
  default     = 1
}

variable "apigw_5xx_threshold" {
  description = "Number of API Gateway 5xx responses within an evaluation period that trips the ingress error alarm. 5xx means the backend failed, so a low threshold catches regressions early."
  type        = number
  default     = 1
}

variable "dlq_depth_threshold" {
  description = "Number of visible messages in the dead-letter queue that trips the DLQ alarm. Any message in the DLQ means a record exhausted its retries, so the threshold is low."
  type        = number
  default     = 1
}

variable "alarm_period_seconds" {
  description = "Length, in seconds, of each metric aggregation period used by the alarms."
  type        = number
  default     = 300
}

variable "alarm_evaluation_periods" {
  description = "Number of consecutive periods the metric must breach the threshold before the alarm fires. 1 favors fast notification over noise-suppression for this low-traffic workload."
  type        = number
  default     = 1
}

# --- Cost budget ------------------------------------------------------------
variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD. The project targets near-$0, so a small budget makes any unexpected spend (a forgotten NAT gateway, runaway Lambda) visible immediately."
  type        = number
  default     = 5
}

variable "budget_notification_threshold_percent" {
  description = "Percentage of the monthly budget that triggers a notification to the SNS topic."
  type        = number
  default     = 80
}

variable "tags" {
  description = "Additional tags merged onto taggable resources. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

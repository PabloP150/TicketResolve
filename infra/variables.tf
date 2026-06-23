variable "environment" {
  description = "Deployment environment for the workspace. Drives naming, tagging and per-environment overrides. Expected values: dev, prod."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of 'dev', 'staging' or 'prod'."
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

variable "dns_subdomain" {
  description = "Delegated DNS subdomain the team controls for TLS (Delivery 5, Deliverable D). The public Route53 hosted zone for it is created in the bootstrap workspace; this workspace looks it up to issue the ACM certificate and create the custom-domain alias records."
  type        = string
  default     = "grupo7.oyd.solid.com.gt"
}

variable "kms_admin_principal_arns" {
  description = "Stable IAM principal ARNs (besides the CI runner role) allowed to administer the CMK, matched against aws:PrincipalArn. Defaults to the human operator user so both CI and a local operator can manage the key. Use ROLE/USER ARNs — never assumed-role session ARNs."
  type        = list(string)
  default     = ["arn:aws:iam::010526283195:user/Pablo-Pineda"]
}

variable "enable_tls" {
  description = "Whether to provision the TLS layer (ACM cert, API Gateway custom domain, CloudFront). Defaults to true (the committed config for the one-click proof). Set to false for an interim apply BEFORE the instructor's NS delegation is live, since ACM DNS validation would otherwise hang. Flip back to true once `dig NS grupo7.oyd.solid.com.gt` returns our name servers."
  type        = bool
  default     = true
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

variable "bucket_force_destroy" {
  description = "Whether the S3 buckets allow terraform destroy to empty them first. true for ephemeral dev/staging that are torn down and rebuilt; false for prod where accidental data loss must be impossible."
  type        = bool
  default     = false
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

# --- Async messaging (Delivery 4) -------------------------------------------

variable "queue_visibility_timeout_seconds" {
  description = "SQS main queue visibility timeout. Must be >= the consumer Lambda timeout (60s) so a slow invocation does not trigger a duplicate delivery before it finishes."
  type        = number
  default     = 90
}

variable "queue_message_retention_seconds" {
  description = "How long the main SQS queue keeps an unconsumed message, in seconds. Differs between dev and staging to demonstrate the multi-environment layout."
  type        = number
  default     = 345600 # 4 days
}

variable "queue_max_receive_count" {
  description = "Number of failed receives before a message is moved from the main queue to the DLQ via the redrive_policy."
  type        = number
  default     = 5
}

variable "dlq_message_retention_seconds" {
  description = "How long the dead-letter queue keeps a failed message, in seconds. Longer than the main queue retention so operators can inspect and replay poison messages."
  type        = number
  default     = 1209600 # 14 days (max)
}

# --- Event-driven compute (Delivery 4) --------------------------------------

variable "event_source_batch_size" {
  description = "Maximum number of SQS messages the event source mapping delivers to the consumer Lambda in a single invocation."
  type        = number
  default     = 10
}

variable "event_source_max_batching_window_seconds" {
  description = "Maximum seconds the event source mapping waits to gather a full batch before invoking the consumer. Trades latency for fewer invocations."
  type        = number
  default     = 5
}

variable "event_source_bisect_on_error" {
  description = "When true, enables SQS partial batch responses (ReportBatchItemFailures) on the event source mapping so a single poison message is isolated and only it is retried / dead-lettered — the SQS analogue of bisect-on-error (which itself applies only to Kinesis/DynamoDB stream sources). The consumer returns the failed messageIds in batchItemFailures."
  type        = bool
  default     = true
}

variable "consumer_reserved_concurrency" {
  description = "Reserved concurrency cap for the SQS consumer (notificacion) Lambda. Bounds how many invocations run at once so a queue flood cannot exhaust downstream throughput (DynamoDB/RDS). NOTE: this AWS account is unverified and its total concurrency limit is the floor of 10, where AWS requires >= 10 unreserved — so any reservation is rejected. Left null until a concurrency-limit increase is granted; the module fully supports a numeric value for prod."
  type        = number
  default     = null
}

# --- Scheduled job (Delivery 4) ---------------------------------------------

variable "sla_sweep_schedule_expression" {
  description = "EventBridge Scheduler expression for the SLA-sweep run of the escalamiento Lambda. rate(...) or cron(...). Frequency differs between dev and staging."
  type        = string
  default     = "rate(1 day)"
}

variable "scheduler_timezone" {
  description = "IANA time zone the scheduler expression is evaluated in."
  type        = string
  default     = "America/Guatemala"
}

# --- Sensitive runtime credential (Delivery 4) ------------------------------

variable "db_password" {
  description = "Sensitive seed value for the Secrets Manager DB-password secret (Delivery 5). Only used to create the initial secret version; the authoritative value is then managed inside Secrets Manager (ignore_changes), so this no longer needs a TF_VAR_db_password GitHub secret. Never committed to a .tfvars file."
  type        = string
  default     = "CHANGEME-set-real-value-in-secrets-manager"
  sensitive   = true
}

# --- Observability (Delivery 5, Deliverable E) ------------------------------

variable "log_retention_days" {
  description = "Retention, in days, for every Lambda CloudWatch log group. Set per environment in <env>.tfvars."
  type        = number
  default     = 14
}

variable "alarm_notification_email" {
  description = "Email subscribed to the SNS alarm/budget topic. AWS sends a one-time confirmation email that must be accepted before notifications are delivered."
  type        = string
}

variable "notifications_email" {
  description = "Email subscribed to the application notifications SNS topic (ticket escalations/resolutions, report-ready links — US-05/US-06). AWS sends a one-time confirmation email that must be accepted. Leave empty to create the topic without an email subscription."
  type        = string
  default     = ""
}

variable "log_level" {
  description = "Log level injected into every application Lambda (LOG_LEVEL env var). DEBUG/INFO/WARNING/ERROR."
  type        = string
  default     = "INFO"
}

variable "lambda_error_threshold" {
  description = "Lambda Errors count within an evaluation period that trips the per-function error alarm."
  type        = number
  default     = 1
}

variable "apigw_5xx_threshold" {
  description = "API Gateway 5xx count within an evaluation period that trips the ingress error alarm."
  type        = number
  default     = 1
}

variable "dlq_depth_threshold" {
  description = "Visible DLQ message count that trips the dead-letter-queue alarm."
  type        = number
  default     = 1
}

variable "alarm_period_seconds" {
  description = "Length, in seconds, of each alarm metric aggregation period."
  type        = number
  default     = 300
}

variable "alarm_evaluation_periods" {
  description = "Number of consecutive breaching periods before an alarm fires."
  type        = number
  default     = 1
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD. The project targets near-$0, so a small budget surfaces unexpected spend immediately."
  type        = number
  default     = 5
}

variable "budget_notification_threshold_percent" {
  description = "Percentage of the monthly budget that triggers an SNS notification."
  type        = number
  default     = 80
}

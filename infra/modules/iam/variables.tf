variable "environment" {
  description = "Deployment environment (dev/staging/prod). Surfaced in role names and tags so roles never collide across environments."
  type        = string
}

variable "project_name" {
  description = "Application/project name (e.g. ticketresolve). Prefix for every role and policy name created by this module."
  type        = string
}

variable "region" {
  description = "AWS region. Used to construct each Lambda's CloudWatch log-group ARN so the logs statement is scoped to that function's own log group (no wildcard)."
  type        = string
}

variable "account_id" {
  description = "AWS account id. Used to construct log-group and Lambda ARNs and to anchor the OIDC trust policy."
  type        = string
}

# --- Resource ARNs the service roles are scoped to ---------------------------
variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table. Compute roles are scoped to this ARN plus its GSIs — never a wildcard."
  type        = string
}

variable "dynamodb_gsi_arns" {
  description = "List of GSI ARNs (GSI1, GSI2) the compute roles may query. Combined with the table ARN to form the scoped DynamoDB resource list."
  type        = list(string)
}

variable "attachments_bucket_arn" {
  description = "ARN of the attachments S3 bucket. The api and async-consumer roles get object-level access scoped to this bucket's objects."
  type        = string
}

variable "reports_bucket_arn" {
  description = "ARN of the reports S3 bucket. The reporte role gets s3:PutObject scoped to this bucket's objects."
  type        = string
}

variable "queue_arn" {
  description = "ARN of the SQS events queue. The api role may SendMessage; the async-consumer role may Receive/Delete/GetQueueAttributes — both scoped to this single ARN."
  type        = string
}

variable "escalamiento_function_arn" {
  description = "ARN of the escalamiento Lambda. The scheduler role may lambda:InvokeFunction ONLY this function ARN. Passed as a constructed string from the root module to avoid a dependency cycle."
  type        = string
}

variable "reporte_function_arn" {
  description = "ARN of the reporte-pdf Lambda. The api-tickets role may lambda:InvokeFunction ONLY this function ARN (async report trigger, US-06). Constructed string to avoid a dependency cycle."
  type        = string
}

variable "notifications_topic_arn" {
  description = "ARN of the application notifications SNS topic. The async-consumer (notificacion) role is granted sns:Publish scoped to this single topic."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the project CMK. The async-consumer role is granted kms:Decrypt on this key so S3/SSE-KMS object reads and the secret decrypt succeed."
  type        = string
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager DB-password secret. The async-consumer role is granted secretsmanager:GetSecretValue scoped to this single secret."
  type        = string
}

# --- Lambda function names (used to build scoped log-group ARNs) -------------
variable "api_tickets_function_name" {
  description = "Name of the api-tickets Lambda. Used to scope the compute_api role's logs statement to /aws/lambda/<name>."
  type        = string
}

variable "webhook_function_name" {
  description = "Name of the webhook-ingesta Lambda. Used to scope the compute_webhook role's logs statement."
  type        = string
}

variable "escalamiento_function_name" {
  description = "Name of the escalamiento Lambda. Used to scope the compute_escalamiento role's logs statement."
  type        = string
}

variable "notificacion_function_name" {
  description = "Name of the notificacion (async consumer) Lambda. Used to scope the async_consumer role's logs statement."
  type        = string
}

variable "reporte_function_name" {
  description = "Name of the reporte-pdf Lambda. Used to scope the compute_reporte role's logs statement."
  type        = string
}

# NOTE (Delivery 5): OIDC provider / CI runner inputs were removed — those
# resources now live in infra/bootstrap/ (CI prerequisites that survive a
# main-workspace destroy).

variable "tags" {
  description = "Additional tags merged onto every role and policy. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

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

# --- OIDC / CI runner --------------------------------------------------------
variable "github_repo" {
  description = "GitHub repository in <org>/<repo> form. The CI runner trust policy is scoped to this repository's subject claims so no other repo (or a fork's PR) can assume the role."
  type        = string
  default     = "PabloP150/TicketResolve"
}

variable "oidc_audience" {
  description = "Audience claim required on the GitHub OIDC token. AWS STS expects sts.amazonaws.com."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "oidc_provider_url" {
  description = "Issuer URL of the GitHub Actions OIDC provider (without scheme in some contexts; the full https URL here)."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

variable "github_oidc_thumbprints" {
  description = "TLS thumbprints of the GitHub OIDC issuer. AWS validates token.actions.githubusercontent.com against its own trust store, but the provider resource still requires a thumbprint list."
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

variable "allowed_oidc_subjects" {
  description = "Exact GitHub OIDC subject claims allowed to assume the CI runner role (StringEquals, no wildcard). Includes the main branch ref plus the dev/staging environment subjects used by the workflows."
  type        = list(string)
  default = [
    "repo:PabloP150/TicketResolve:ref:refs/heads/main",
    "repo:PabloP150/TicketResolve:environment:dev",
    "repo:PabloP150/TicketResolve:environment:staging",
  ]
}

variable "tags" {
  description = "Additional tags merged onto every role and policy. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

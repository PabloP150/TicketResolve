data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Security foundation (Delivery 5) — the CMK + Secrets Manager secret (B) and
# the centralized IAM roles + GitHub OIDC provider (A, C). Created before the
# compute/storage/database resources that consume their outputs.
# ---------------------------------------------------------------------------
module "security_kms" {
  source = "./modules/security_kms"

  environment              = var.environment
  project_name             = var.app_name
  region                   = local.region
  account_id               = local.account_id
  db_password              = var.db_password
  key_admin_principal_arns = local.kms_key_admin_principal_arns

  tags = {
    Application = var.app_name
  }
}

module "iam" {
  source = "./modules/iam"

  environment  = var.environment
  project_name = var.app_name
  region       = local.region
  account_id   = local.account_id

  dynamodb_table_arn     = module.database.table_arn
  dynamodb_gsi_arns      = [module.database.gsi1_arn, module.database.gsi2_arn]
  attachments_bucket_arn = module.attachments_bucket.bucket_arn
  reports_bucket_arn     = module.reports_bucket.bucket_arn
  queue_arn              = module.events_queue.queue_arn

  escalamiento_function_arn = local.escalamiento_function_arn
  kms_key_arn               = module.security_kms.kms_key_arn
  secret_arn                = module.security_kms.secret_arn

  api_tickets_function_name  = local.lambda_names.api_tickets
  webhook_function_name      = local.lambda_names.webhook_ingesta
  escalamiento_function_name = local.lambda_names.escalamiento
  notificacion_function_name = local.lambda_names.notificacion
  reporte_function_name      = local.lambda_names.reporte_pdf

  github_repo = var.github_repo

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# Storage — two buckets via the same module with different lifecycle policies.
# Lifecycle scope is enforced with prefixes per the rubric.
# ---------------------------------------------------------------------------

module "attachments_bucket" {
  source = "./modules/storage"

  bucket_name   = local.attachments_bucket_name
  environment   = var.environment
  force_destroy = var.bucket_force_destroy
  kms_key_arn   = module.security_kms.kms_key_arn

  lifecycle_rules = [
    {
      id                       = "attachments-tier-down"
      prefix                   = "attachments/"
      transition_days          = 30
      transition_storage_class = "STANDARD_IA"
      expiration_days          = 365
    },
  ]

  tags = {
    Application = var.app_name
    Purpose     = "ticket-attachments"
  }
}

module "reports_bucket" {
  source = "./modules/storage"

  bucket_name   = local.reports_bucket_name
  environment   = var.environment
  force_destroy = var.bucket_force_destroy
  kms_key_arn   = module.security_kms.kms_key_arn

  lifecycle_rules = [
    {
      id              = "reports-expire"
      prefix          = "reports/"
      expiration_days = 90
    },
  ]

  tags = {
    Application = var.app_name
    Purpose     = "monthly-report-archive"
  }
}

# ---------------------------------------------------------------------------
# Database — DynamoDB single-table with GSI1 (engineer dashboard) and GSI2 (hash dedup).
# ---------------------------------------------------------------------------

module "database" {
  source = "./modules/database"

  table_name  = local.database_table_name
  environment = var.environment
  kms_key_arn = module.security_kms.kms_key_arn

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# Async messaging (Delivery 4) — SQS events queue + DLQ. All settings flow from
# root variables / <env>.tfvars; the producer (api-tickets) and the consumer
# (notificacion, via an event source mapping) are wired to its outputs below.
# ---------------------------------------------------------------------------
module "events_queue" {
  source = "./modules/async"

  queue_name_prefix             = local.queue_name_prefix
  visibility_timeout_seconds    = var.queue_visibility_timeout_seconds
  message_retention_seconds     = var.queue_message_retention_seconds
  max_receive_count             = var.queue_max_receive_count
  dlq_message_retention_seconds = var.dlq_message_retention_seconds

  tags = {
    Application = var.app_name
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# Compute — five Lambdas, each instantiated from the same compute module.
# As of Delivery 5 each function's execution role is defined centrally in
# module.iam (one explicitly scoped, wildcard-free role per service) and wired
# in via execution_role_arn — no inline IAM statements live here anymore.
# ---------------------------------------------------------------------------

module "lambda_api_tickets" {
  source = "./modules/compute"

  function_name = local.lambda_names.api_tickets
  environment   = var.environment
  memory_size   = 512
  timeout       = var.lambda_timeout_default

  # Real handler for the Delivery 3 end-to-end proof (GET DynamoDB / POST S3).
  source_dir = "${path.module}/lambda_src/api_tickets"

  execution_role_arn = module.iam.compute_api_role_arn

  environment_variables = {
    TABLE_NAME         = module.database.table_name
    ATTACHMENTS_BUCKET = module.attachments_bucket.bucket_name
    # Delivery 4 — producer target queue, wired from the async module output.
    QUEUE_URL = module.events_queue.queue_url
  }
}

module "lambda_webhook_ingesta" {
  source = "./modules/compute"

  function_name = local.lambda_names.webhook_ingesta
  environment   = var.environment
  memory_size   = 512
  timeout       = var.lambda_timeout_default

  execution_role_arn = module.iam.compute_webhook_role_arn

  environment_variables = {
    TABLE_NAME = module.database.table_name
  }
}

module "lambda_escalamiento" {
  source = "./modules/compute"

  function_name = local.lambda_names.escalamiento
  environment   = var.environment
  memory_size   = var.lambda_memory_default
  timeout       = 60

  execution_role_arn = module.iam.compute_escalamiento_role_arn

  environment_variables = {
    TABLE_NAME = module.database.table_name
  }
}

module "lambda_notificacion" {
  source = "./modules/compute"

  function_name = local.lambda_names.notificacion
  environment   = var.environment
  memory_size   = var.lambda_memory_default
  # Consumer timeout (60s) must be <= the queue visibility timeout (90s) so a
  # slow invocation cannot let the same message be re-delivered mid-flight.
  timeout = 60

  # Delivery 4 — real async consumer handler: reads SQS records, writes to S3.
  source_dir = "${path.module}/lambda_src/notificacion"

  # Bound concurrency so a queue flood cannot exhaust downstream throughput.
  reserved_concurrent_executions = var.consumer_reserved_concurrency

  execution_role_arn = module.iam.async_consumer_role_arn

  environment_variables = {
    ATTACHMENTS_BUCKET = module.attachments_bucket.bucket_name
    # Delivery 5 — only the secret ARN is injected (never the value). The
    # handler calls GetSecretValue at startup, retiring the TF_VAR_db_password
    # plaintext env-var pattern from Delivery 3/4.
    DB_SECRET_ARN = module.security_kms.secret_arn
  }
}

# ---------------------------------------------------------------------------
# Event-driven compute (Delivery 4, Deliverable B) — connect the SQS events
# queue to the notificacion consumer. Queue ARN and function name come from
# module outputs (no hardcoded ARNs). Batch and bisect settings are variables.
# ---------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "events_to_notificacion" {
  event_source_arn                   = module.events_queue.queue_arn
  function_name                      = module.lambda_notificacion.function_arn
  batch_size                         = var.event_source_batch_size
  maximum_batching_window_in_seconds = var.event_source_max_batching_window_seconds

  # bisect-on-error is a Kinesis/DynamoDB-stream concept. The SQS equivalent for
  # isolating a poison message from its batch is partial batch responses: the
  # handler returns the failed messageIds and only those go back to the queue
  # (eventually to the DLQ), instead of re-failing the whole batch.
  function_response_types = var.event_source_bisect_on_error ? ["ReportBatchItemFailures"] : []

  enabled = true
}

module "lambda_reporte_pdf" {
  source = "./modules/compute"

  function_name = local.lambda_names.reporte_pdf
  environment   = var.environment
  memory_size   = 1024
  timeout       = 60

  execution_role_arn = module.iam.compute_reporte_role_arn

  environment_variables = {
    TABLE_NAME     = module.database.table_name
    REPORTS_BUCKET = module.reports_bucket.bucket_name
  }
}

# ---------------------------------------------------------------------------
# Network — VPC, subnets (public / private-app / private-data x 2 AZs), IGW,
# NAT Gateway, route tables and S3/DynamoDB Gateway Endpoints. Every input is
# wired from root variables/locals — no hardcoded CIDRs in the module call.
# ---------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_prefix = local.name_prefix
  environment = var.environment

  vpc_cidr                  = var.vpc_cidr
  availability_zones        = var.availability_zones
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  enable_nat_gateway        = var.enable_nat_gateway
  single_nat_gateway        = var.single_nat_gateway

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# Security — tiered web/app/db security groups (SG-to-SG rules) plus public
# and private network ACLs. Consumes the VPC id and subnet ids from network.
# ---------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  name_prefix = local.name_prefix
  environment = var.environment

  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  web_ingress_cidrs = var.web_ingress_cidrs
  http_port         = var.http_port
  https_port        = var.https_port
  app_port          = var.app_port
  db_port           = var.db_port

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# Ingress — API Gateway HTTP API (Lambda proxy). Public entry point for the
# compute layer. Consumes the api-tickets and webhook Lambda invoke ARNs.
# ---------------------------------------------------------------------------
module "ingress" {
  source = "./modules/ingress"

  api_name          = local.api_name
  environment       = var.environment
  health_check_path = var.health_check_path

  api_tickets_invoke_arn    = module.lambda_api_tickets.invoke_arn
  api_tickets_function_name = module.lambda_api_tickets.function_name
  webhook_invoke_arn        = module.lambda_webhook_ingesta.invoke_arn
  webhook_function_name     = module.lambda_webhook_ingesta.function_name

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# TLS termination (Delivery 5, Deliverable D) — a regional ACM certificate
# bound to an API Gateway custom domain (api.<subdomain>) plus a CloudFront
# distribution (app.<subdomain>) that adds the explicit HTTP->HTTPS 301. The
# delegated Route53 zone is created in the bootstrap workspace and looked up
# here. Requires the instructor's NS delegation to be live before apply so the
# DNS-based certificate validation can complete.
# ---------------------------------------------------------------------------
module "tls" {
  source = "./modules/tls"
  count  = var.enable_tls ? 1 : 0

  environment = var.environment
  subdomain   = var.dns_subdomain
  api_id      = module.ingress.api_id

  # dev (the graded environment) gets clean api/app labels; other environments
  # get an env suffix so they never collide on the shared delegated zone.
  api_subdomain_label = var.environment == "dev" ? "api" : "api-${var.environment}"
  app_subdomain_label = var.environment == "dev" ? "app" : "app-${var.environment}"

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# Scheduled job (Delivery 4, Deliverable C) — EventBridge Scheduler invokes the
# escalamiento Lambda on a cadence to sweep open tickets past their SLA. This
# target is DISTINCT from the async consumer (notificacion). The scheduler's
# dedicated role may only lambda:InvokeFunction the escalamiento ARN — narrower
# than escalamiento's own role (which can read/write DynamoDB).
# ---------------------------------------------------------------------------
module "sla_sweep_scheduler" {
  source = "./modules/scheduler"

  schedule_name       = local.sla_sweep_schedule_name
  schedule_expression = var.sla_sweep_schedule_expression
  scheduler_timezone  = var.scheduler_timezone
  target_lambda_arn   = module.lambda_escalamiento.function_arn
  target_lambda_name  = module.lambda_escalamiento.function_name
  scheduler_role_arn  = module.iam.scheduler_role_arn
}

# ---------------------------------------------------------------------------
# Observability (Delivery 5, Deliverable E) — log groups (one per Lambda),
# metric alarms wired to an SNS email topic, a CloudWatch dashboard and a
# monthly cost budget. Every input is wired from root variables/locals.
# ---------------------------------------------------------------------------
module "observability" {
  source = "./modules/observability"

  environment  = var.environment
  project_name = var.app_name
  region       = local.region

  lambda_function_names = local.lambda_names
  log_retention_days    = var.log_retention_days

  api_id     = module.ingress.api_id
  queue_name = module.events_queue.queue_name
  dlq_name   = module.events_queue.dlq_name

  notification_email = var.alarm_notification_email

  lambda_error_threshold   = var.lambda_error_threshold
  apigw_5xx_threshold      = var.apigw_5xx_threshold
  dlq_depth_threshold      = var.dlq_depth_threshold
  alarm_period_seconds     = var.alarm_period_seconds
  alarm_evaluation_periods = var.alarm_evaluation_periods

  monthly_budget_usd                    = var.monthly_budget_usd
  budget_notification_threshold_percent = var.budget_notification_threshold_percent

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# Seed data for the E2E proof — committed to the repo (not inserted via the
# console). The GET /api/v1/incidents endpoint reads exactly this item.
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table_item" "seed_ticket" {
  table_name = module.database.table_name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK       = { S = "TICKET#seed" }
    SK       = { S = "META" }
    GSI1PK   = { S = "ASSIGN#unassigned" }
    GSI1SK   = { S = "STATUS#OPEN#SLA#2026-06-07T23:55:00Z" }
    title    = { S = "Seed incident for the Delivery 3 end-to-end proof" }
    severity = { S = "P2" }
    status   = { S = "OPEN" }
    source   = { S = "terraform-seed" }
  })

  lifecycle {
    # The seed item proves the read path; ignore drift if the handler ever
    # mutates it, so a later apply does not fight application writes.
    ignore_changes = [item]
  }
}

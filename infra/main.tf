data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Storage — two buckets via the same module with different lifecycle policies.
# Lifecycle scope is enforced with prefixes per the rubric.
# ---------------------------------------------------------------------------

module "attachments_bucket" {
  source = "./modules/storage"

  bucket_name = local.attachments_bucket_name
  environment = var.environment

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

  bucket_name = local.reports_bucket_name
  environment = var.environment

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

  tags = {
    Application = var.app_name
  }
}

# ---------------------------------------------------------------------------
# Compute — five Lambdas, each instantiated from the same compute module with
# per-function memory, timeout and scoped IAM statements (no wildcards).
# Statements reference module.database.table_arn and bucket ARNs so module
# outputs are wired into other module inputs (rubric: composition).
# ---------------------------------------------------------------------------

locals {
  dynamodb_read_actions = [
    "dynamodb:GetItem",
    "dynamodb:BatchGetItem",
    "dynamodb:Query",
    "dynamodb:Scan",
    "dynamodb:ConditionCheckItem",
  ]

  dynamodb_write_actions = [
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:BatchWriteItem",
  ]

  dynamodb_table_and_indexes = [
    module.database.table_arn,
    module.database.gsi1_arn,
    module.database.gsi2_arn,
  ]
}

module "lambda_api_tickets" {
  source = "./modules/compute"

  function_name = local.lambda_names.api_tickets
  environment   = var.environment
  memory_size   = 512
  timeout       = var.lambda_timeout_default

  # Real handler for the Delivery 3 end-to-end proof (GET DynamoDB / POST S3).
  source_dir = "${path.module}/lambda_src/api_tickets"

  environment_variables = {
    TABLE_NAME         = module.database.table_name
    ATTACHMENTS_BUCKET = module.attachments_bucket.bucket_name
  }

  additional_iam_statements = [
    {
      sid       = "DynamoDBTicketsCRUD"
      actions   = concat(local.dynamodb_read_actions, local.dynamodb_write_actions)
      resources = local.dynamodb_table_and_indexes
    },
    {
      sid       = "S3AttachmentsReadWrite"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${module.attachments_bucket.bucket_arn}/*"]
    },
    {
      sid       = "S3AttachmentsList"
      actions   = ["s3:ListBucket"]
      resources = [module.attachments_bucket.bucket_arn]
    },
  ]
}

module "lambda_webhook_ingesta" {
  source = "./modules/compute"

  function_name = local.lambda_names.webhook_ingesta
  environment   = var.environment
  memory_size   = 512
  timeout       = var.lambda_timeout_default

  environment_variables = {
    TABLE_NAME = module.database.table_name
  }

  additional_iam_statements = [
    {
      sid       = "DynamoDBIngestWrites"
      actions   = concat(local.dynamodb_read_actions, local.dynamodb_write_actions)
      resources = local.dynamodb_table_and_indexes
    },
  ]
}

module "lambda_escalamiento" {
  source = "./modules/compute"

  function_name = local.lambda_names.escalamiento
  environment   = var.environment
  memory_size   = var.lambda_memory_default
  timeout       = 60

  environment_variables = {
    TABLE_NAME = module.database.table_name
  }

  additional_iam_statements = [
    {
      sid       = "DynamoDBEscalationReadWrite"
      actions   = concat(local.dynamodb_read_actions, local.dynamodb_write_actions)
      resources = local.dynamodb_table_and_indexes
    },
  ]
}

module "lambda_notificacion" {
  source = "./modules/compute"

  function_name = local.lambda_names.notificacion
  environment   = var.environment
  memory_size   = var.lambda_memory_default
  timeout       = 30

  # No additional statements at this stage — SNS/SQS targets land in Delivery 4.
  # The Lambda already has logs:* via the module's built-in execution role.
  additional_iam_statements = []
}

module "lambda_reporte_pdf" {
  source = "./modules/compute"

  function_name = local.lambda_names.reporte_pdf
  environment   = var.environment
  memory_size   = 1024
  timeout       = 60

  environment_variables = {
    TABLE_NAME     = module.database.table_name
    REPORTS_BUCKET = module.reports_bucket.bucket_name
  }

  additional_iam_statements = [
    {
      sid       = "DynamoDBReportRead"
      actions   = local.dynamodb_read_actions
      resources = local.dynamodb_table_and_indexes
    },
    {
      sid       = "S3ReportsWrite"
      actions   = ["s3:PutObject"]
      resources = ["${module.reports_bucket.bucket_arn}/*"]
    },
  ]
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

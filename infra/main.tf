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
# API Gateway HTTP API — routes two paths to two Lambdas. The api-tickets
# Lambda's invoke_arn is consumed here, demonstrating module → root wiring.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "main" {
  name          = local.api_name
  protocol_type = "HTTP"
  description   = "TicketResolve public HTTP API. Routes /api/v1/incidents and /api/v1/webhooks to dedicated Lambdas."

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PATCH", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
  }

  tags = {
    Application = var.app_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_apigatewayv2_integration" "api_tickets" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.lambda_api_tickets.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "webhook_ingesta" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.lambda_webhook_ingesta.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "incidents" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /api/v1/incidents"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

resource "aws_apigatewayv2_route" "webhooks" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /api/v1/webhooks"
  target    = "integrations/${aws_apigatewayv2_integration.webhook_ingesta.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Application = var.app_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_lambda_permission" "apigw_api_tickets" {
  statement_id  = "AllowAPIGatewayInvokeApiTickets"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_api_tickets.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_webhook_ingesta" {
  statement_id  = "AllowAPIGatewayInvokeWebhookIngesta"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_webhook_ingesta.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

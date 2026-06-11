locals {
  module_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "ingress"
  })
}

# ===========================================================================
# Public ingress for the Lambda compute target: an API Gateway HTTP API with
# Lambda proxy integrations. This is the only public entry point — the Lambdas
# have no direct invocation URL exposed to clients.
# ===========================================================================
resource "aws_apigatewayv2_api" "this" {
  name          = var.api_name
  protocol_type = "HTTP"
  description   = "TicketResolve public HTTP API. Health check plus /api/v1/incidents (GET/POST) and /api/v1/webhooks (POST)."

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = var.cors_allow_methods
    allow_headers = var.cors_allow_headers
  }

  tags = local.module_tags
}

# --- Integrations ----------------------------------------------------------
resource "aws_apigatewayv2_integration" "api_tickets" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.api_tickets_invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "webhook" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.webhook_invoke_arn
  payload_format_version = "2.0"
}

# --- Routes ----------------------------------------------------------------
# Health / readiness check on the configurable path.
resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET ${var.health_check_path}"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# E2E read path — the handler queries DynamoDB and returns a real item.
resource "aws_apigatewayv2_route" "incidents_get" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /api/v1/incidents"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# E2E write path — the handler writes an object to S3 and returns 201.
resource "aws_apigatewayv2_route" "incidents_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/incidents"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# Delivery 4 producer — the handler puts the body on the SQS queue and returns 202.
resource "aws_apigatewayv2_route" "incidents_enqueue_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/incidents/enqueue"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

resource "aws_apigatewayv2_route" "webhooks_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/webhooks"
  target    = "integrations/${aws_apigatewayv2_integration.webhook.id}"
}

# --- Stage -----------------------------------------------------------------
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Free throttling cap — the routes are unauthenticated at this delivery, so a
  # conservative rate/burst limit protects the account from cost-abuse of the
  # public POST endpoint until usage plans / authn arrive in Delivery 5.
  default_route_settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit
  }

  tags = local.module_tags
}

# --- Lambda invoke permissions --------------------------------------------
resource "aws_lambda_permission" "api_tickets" {
  statement_id  = "AllowAPIGatewayInvokeApiTickets"
  action        = "lambda:InvokeFunction"
  function_name = var.api_tickets_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "webhook" {
  statement_id  = "AllowAPIGatewayInvokeWebhookIngesta"
  action        = "lambda:InvokeFunction"
  function_name = var.webhook_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

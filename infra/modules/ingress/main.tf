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
  description   = "TicketResolve public HTTPS API. Incidents CRUD + state machine, comments, reassignment, webhook alert ingestion, and async report trigger — all served by the api-tickets Lambda."

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = var.cors_allow_methods
    allow_headers = var.cors_allow_headers
  }

  tags = local.module_tags
}

# --- Integrations ----------------------------------------------------------
# Single proxy integration: the api-tickets Lambda is the real application
# handler and serves every route (incl. webhook alert ingestion via
# /api/v1/webhooks/alerts → service.ingest_alert). The standalone webhook
# placeholder Lambda stays provisioned but is no longer wired to a route.
resource "aws_apigatewayv2_integration" "api_tickets" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.api_tickets_invoke_arn
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

# Create a ticket (US-01).
resource "aws_apigatewayv2_route" "incidents_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/incidents"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# Get a single ticket with its timeline/attachments.
resource "aws_apigatewayv2_route" "incident_get" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /api/v1/incidents/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# State-machine transition: ACK / ESCALATED / RESOLVED (US-05).
resource "aws_apigatewayv2_route" "incident_patch" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "PATCH /api/v1/incidents/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# Add a comment to a ticket (US-05).
resource "aws_apigatewayv2_route" "incident_comments_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/incidents/{id}/comments"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# Reassign a ticket to another engineer.
resource "aws_apigatewayv2_route" "incident_assignee_patch" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "PATCH /api/v1/incidents/{id}/assignee"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# Delivery 4 producer — the handler puts the body on the SQS queue and returns 202.
resource "aws_apigatewayv2_route" "incidents_enqueue_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/incidents/enqueue"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# Webhook alert ingestion with dedup (US-02). Served by api-tickets
# (service.ingest_alert) — the real route is /webhooks/alerts.
resource "aws_apigatewayv2_route" "webhooks_alerts_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/webhooks/alerts"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
}

# Trigger asynchronous monthly PDF report generation (US-06).
resource "aws_apigatewayv2_route" "reports_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/reports"
  target    = "integrations/${aws_apigatewayv2_integration.api_tickets.id}"
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
# One permission covers every route: the source_arn wildcard (/*/*) authorises
# API Gateway to invoke api-tickets for all methods/paths on this API.
resource "aws_lambda_permission" "api_tickets" {
  statement_id  = "AllowAPIGatewayInvokeApiTickets"
  action        = "lambda:InvokeFunction"
  function_name = var.api_tickets_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

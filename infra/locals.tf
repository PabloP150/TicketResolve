locals {
  # Single prefix every module derives its resource names from (e.g. ticketresolve-dev).
  name_prefix = "${var.app_name}-${var.environment}"

  # Derived naming so every resource is built from var.app_name + var.environment, never hardcoded.
  attachments_bucket_name = "${var.app_name}-attachments-${var.environment}-${data.aws_caller_identity.current.account_id}"
  reports_bucket_name     = "${var.app_name}-reports-${var.environment}-${data.aws_caller_identity.current.account_id}"
  database_table_name     = "${var.app_name}-${var.environment}"
  api_name                = "${var.app_name}-api-${var.environment}"

  # Lambda function names — used both as AWS resource identifiers and as CloudWatch log group suffixes.
  lambda_names = {
    api_tickets     = "${var.app_name}-api-tickets-${var.environment}"
    webhook_ingesta = "${var.app_name}-webhook-ingesta-${var.environment}"
    escalamiento    = "${var.app_name}-escalamiento-${var.environment}"
    notificacion    = "${var.app_name}-notificacion-${var.environment}"
    reporte_pdf     = "${var.app_name}-reporte-pdf-${var.environment}"
  }

  # Delivery 4 — async + scheduler naming, all derived from app_name + environment.
  queue_name_prefix       = local.name_prefix                # ticketresolve-dev -> queue ticketresolve-dev-events
  sla_sweep_schedule_name = "${local.name_prefix}-sla-sweep" # EventBridge Scheduler schedule name
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  module_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "observability"
  })
}

# ===========================================================================
# Log groups — one per Lambda, with a configurable retention. The function
# names already embed the environment, so the /aws/lambda/<name> group names
# never collide across environments.
# ===========================================================================
resource "aws_cloudwatch_log_group" "lambda" {
  for_each = var.lambda_function_names

  name              = "/aws/lambda/${each.value}"
  retention_in_days = var.log_retention_days
  tags              = local.module_tags
}

# ===========================================================================
# SNS topic + email subscription — the single notification channel for both
# the metric alarms and the cost budget.
# ===========================================================================
resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-alarms"
  tags = local.module_tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# Allow AWS Budgets and CloudWatch to publish to the topic.
data "aws_iam_policy_document" "topic_policy" {
  statement {
    sid     = "AllowBudgetsPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.alarms.arn]
  }
  statement {
    sid     = "AllowCloudWatchPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    resources = [aws_sns_topic.alarms.arn]
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.topic_policy.json
}

# ===========================================================================
# Metric alarms (all thresholds/periods are variables).
#   1. Per-Lambda Errors alarm (one per function).
#   2. API Gateway 5xx error-rate alarm.
#   3. Dead-letter queue depth alarm.
# Every alarm notifies the SNS topic above.
# ===========================================================================
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.lambda_function_names

  alarm_name          = "${each.value}-errors"
  alarm_description   = "Lambda ${each.value} reported >= ${var.lambda_error_threshold} error(s) in ${var.alarm_period_seconds}s."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.lambda_error_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.module_tags
}

resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${local.name_prefix}-apigw-5xx"
  alarm_description   = "API Gateway returned >= ${var.apigw_5xx_threshold} 5xx response(s) in ${var.alarm_period_seconds}s (backend failures)."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.apigw_5xx_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.module_tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.name_prefix}-dlq-depth"
  alarm_description   = "Dead-letter queue holds >= ${var.dlq_depth_threshold} message(s): a record exhausted its retries and needs investigation."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.dlq_depth_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.dlq_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.module_tags
}

# ===========================================================================
# Dashboard — body generated with jsonencode() referencing Terraform values
# (no hardcoded metric names/ARNs in a heredoc). Three widgets:
#   1. API Gateway request count (ingress traffic)
#   2. Lambda errors across all functions (compute error rate)
#   3. SQS queue + DLQ depth (async health)
# ===========================================================================
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "API Gateway — request count"
          region  = var.region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 300
          metrics = [["AWS/ApiGateway", "Count", "ApiId", var.api_id]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Lambda — errors by function"
          region  = var.region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 300
          metrics = [for name in values(var.lambda_function_names) : ["AWS/Lambda", "Errors", "FunctionName", name]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "SQS — queue vs dead-letter depth"
          region = var.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.queue_name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dlq_name],
          ]
        }
      },
    ]
  })
}

# ===========================================================================
# Cost budget — monthly USD limit with an 80% (configurable) notification to
# the SNS topic. Budget amount is a variable, never a magic number.
# ===========================================================================
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.budget_notification_threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alarms.arn]
  }

  depends_on = [aws_sns_topic_policy.alarms]
}

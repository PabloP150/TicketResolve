locals {
  # The CloudWatch log group for this function is provisioned centrally in
  # infra/modules/observability/ (Delivery 5) with a configurable retention —
  # the compute module no longer creates it. Name kept here for the output.
  log_group_name = "/aws/lambda/${var.function_name}"

  module_tags = merge(var.tags, {
    Environment  = var.environment
    ManagedBy    = "Terraform"
    Module       = "compute"
    FunctionName = var.function_name
  })
}

# Packaging: when var.source_dir is set the module zips that directory as the
# real handler (Delivery 3 E2E endpoints). Otherwise it bundles an inline
# placeholder that returns a static 200 — enough to PROVISION functions whose
# business logic lands in a later delivery.
data "archive_file" "placeholder" {
  count       = var.source_dir == null ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/build/${var.function_name}.zip"

  source {
    filename = "lambda_function.py"
    content  = <<-PYTHON
      """Placeholder handler for ${var.function_name}.
      Returns a static 200 response. Real business logic lands in a later delivery.
      """

      def lambda_handler(event, context):
          return {
              "statusCode": 200,
              "body": '{"status":"ok","function":"${var.function_name}"}',
              "headers": {"Content-Type": "application/json"},
          }
    PYTHON
  }
}

data "archive_file" "from_source" {
  count       = var.source_dir == null ? 0 : 1
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/build/${var.function_name}.zip"
}

locals {
  archive_path = var.source_dir == null ? data.archive_file.placeholder[0].output_path : data.archive_file.from_source[0].output_path
  archive_hash = var.source_dir == null ? data.archive_file.placeholder[0].output_base64sha256 : data.archive_file.from_source[0].output_base64sha256
}

# NOTE (Delivery 5): this module no longer creates its own execution role.
# Roles are now defined centrally in infra/modules/iam/ (one explicitly scoped
# role per service, no wildcards) and the ARN is injected via
# var.execution_role_arn. The per-function CloudWatch log group stays here.

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  role          = var.execution_role_arn
  runtime       = var.runtime
  handler       = var.handler
  memory_size   = var.memory_size
  timeout       = var.timeout

  reserved_concurrent_executions = var.reserved_concurrent_executions

  filename         = local.archive_path
  source_code_hash = local.archive_hash

  environment {
    variables = merge(var.environment_variables, {
      ENV           = var.environment
      FUNCTION_NAME = var.function_name
    })
  }

  tags = local.module_tags
}

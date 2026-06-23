variable "function_name" {
  description = "Full Lambda function name. Used as the AWS resource identifier and as the CloudWatch log group name suffix (/aws/lambda/<function_name>)."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev/prod). Surfaced in tags and in the Lambda's environment variables under ENV."
  type        = string
}

variable "memory_size" {
  description = "Memory allocated to the Lambda in MB. Drives CPU proportionally. Free tier covers 400K GB-seconds/month."
  type        = number
  default     = 256

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 MB (Lambda hard limits)."
  }
}

variable "timeout" {
  description = "Maximum execution time in seconds before Lambda terminates the invocation. Hard ceiling: 900 seconds."
  type        = number
  default     = 10

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "runtime" {
  description = "Lambda managed runtime identifier (e.g. python3.12, nodejs20.x). Must match the language of the handler code."
  type        = string
  default     = "python3.12"
}

variable "handler" {
  description = "Handler entrypoint in the form <file>.<function>. Must match a callable inside the bundled code."
  type        = string
  default     = "lambda_function.lambda_handler"
}

variable "environment_variables" {
  description = "Extra environment variables to inject into the Lambda. The module always sets ENV and FUNCTION_NAME automatically."
  type        = map(string)
  default     = {}
}

variable "source_dir" {
  description = "Optional path to a directory with real handler code to package. When null (default) the module bundles an inline placeholder handler. When set, the directory is zipped as the function source."
  type        = string
  default     = null
}

variable "execution_role_arn" {
  description = "ARN of the Lambda execution role. As of Delivery 5 the role is defined centrally in infra/modules/iam/ (one explicitly scoped role per service, no wildcards) and injected here — the compute module no longer creates roles."
  type        = string
}

variable "reserved_concurrent_executions" {
  description = "Caps the number of concurrent executions of this function. Set on the SQS consumer so a flood of queue messages cannot spawn enough concurrent invocations to exhaust a downstream connection pool (DynamoDB/RDS). null (default) leaves the function on the shared unreserved pool."
  type        = number
  default     = null

  validation {
    # Ternary (not ||) so the >= 0 comparison is never evaluated against null —
    # some Terraform versions do not short-circuit validation conditions.
    condition     = var.reserved_concurrent_executions == null ? true : var.reserved_concurrent_executions >= 0
    error_message = "reserved_concurrent_executions must be null or a non-negative number."
  }
}

variable "tags" {
  description = "Additional tags to merge on every resource created by this module. The module adds Environment, ManagedBy, Module and FunctionName tags automatically."
  type        = map(string)
  default     = {}
}

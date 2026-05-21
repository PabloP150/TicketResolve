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

variable "additional_iam_statements" {
  description = "Service-specific IAM statements appended to the Lambda's execution role. Each statement must specify explicit actions and resource ARNs — wildcards are not permitted (rubric requirement)."
  type = list(object({
    sid       = string
    actions   = list(string)
    resources = list(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for s in var.additional_iam_statements :
      !contains(s.actions, "*") && !anytrue([for r in s.resources : r == "*"])
    ])
    error_message = "Wildcard actions or resources are not permitted in additional_iam_statements (rubric: 'no wildcard Action or Resource')."
  }
}

variable "log_retention_in_days" {
  description = "Retention for the Lambda's CloudWatch log group. 14 days is enough for the academic project and stays inside the free tier of CloudWatch Logs ingestion."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Additional tags to merge on every resource created by this module. The module adds Environment, ManagedBy, Module and FunctionName tags automatically."
  type        = map(string)
  default     = {}
}

variable "api_name" {
  description = "Name of the API Gateway HTTP API. Derived in the root from app_name + environment."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev/prod). Surfaced in tags."
  type        = string
}

variable "health_check_path" {
  description = "Path exposed as a lightweight health/readiness check on the ingress. Routed (GET) to the api-tickets Lambda."
  type        = string
  default     = "/"
}

variable "cors_allow_origins" {
  description = "Allowed CORS origins for the HTTP API."
  type        = list(string)
  default     = ["*"]
}

variable "cors_allow_methods" {
  description = "Allowed CORS methods for the HTTP API."
  type        = list(string)
  default     = ["GET", "POST", "PATCH", "OPTIONS"]
}

variable "cors_allow_headers" {
  description = "Allowed CORS headers for the HTTP API."
  type        = list(string)
  default     = ["content-type", "authorization"]
}

variable "api_tickets_invoke_arn" {
  description = "Invoke ARN of the api-tickets Lambda. Serves the health check, GET /api/v1/incidents and POST /api/v1/incidents routes."
  type        = string
}

variable "api_tickets_function_name" {
  description = "Function name of the api-tickets Lambda. Used to grant API Gateway invoke permission."
  type        = string
}

variable "webhook_invoke_arn" {
  description = "Invoke ARN of the webhook-ingesta Lambda. Serves POST /api/v1/webhooks."
  type        = string
}

variable "webhook_function_name" {
  description = "Function name of the webhook-ingesta Lambda. Used to grant API Gateway invoke permission."
  type        = string
}

variable "throttling_rate_limit" {
  description = "Steady-state request rate (req/s) the $default stage allows before throttling. Low default caps cost-abuse on the unauthenticated endpoints; raise it once authn/usage plans land in Delivery 5."
  type        = number
  default     = 10
}

variable "throttling_burst_limit" {
  description = "Maximum burst of concurrent requests the $default stage absorbs before throttling."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Additional tags merged onto every resource created by this module."
  type        = map(string)
  default     = {}
}

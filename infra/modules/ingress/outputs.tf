output "api_id" {
  description = "ID of the API Gateway HTTP API."
  value       = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  description = "Base HTTPS endpoint of the HTTP API ($default stage). Public ingress URL for all routes."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "execution_arn" {
  description = "Execution ARN of the API. Useful for scoping additional Lambda permissions."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "health_check_url" {
  description = "Fully-qualified health check URL (api_endpoint + health_check_path)."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}${var.health_check_path}"
}

output "incidents_url" {
  description = "Fully-qualified URL of the /api/v1/incidents resource (E2E GET/POST endpoint)."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/api/v1/incidents"
}

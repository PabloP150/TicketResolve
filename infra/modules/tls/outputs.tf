output "certificate_arn" {
  description = "ARN of the validated ACM certificate covering api.<subdomain> and app.<subdomain>."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "api_fqdn" {
  description = "Public HTTPS URL of the API Gateway custom domain (api.<subdomain>). Serves HTTPS only with the regional certificate."
  value       = local.api_fqdn
}

output "app_fqdn" {
  description = "Public URL fronted by CloudFront (app.<subdomain>). HTTPS plus an HTTP 301 redirect to HTTPS."
  value       = local.app_fqdn
}

output "api_url" {
  description = "Full https:// URL for the API Gateway custom domain."
  value       = "https://${local.api_fqdn}"
}

output "app_url" {
  description = "Full https:// URL for the CloudFront endpoint."
  value       = "https://${local.app_fqdn}"
}

output "cloudfront_domain_name" {
  description = "The *.cloudfront.net domain of the distribution (for debugging / direct access)."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "apigw_target_domain_name" {
  description = "The regional target domain name of the API Gateway custom domain (the alias target)."
  value       = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].target_domain_name
}

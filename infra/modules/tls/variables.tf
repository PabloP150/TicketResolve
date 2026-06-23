variable "environment" {
  description = "Deployment environment (dev/staging/prod). Surfaced in tags."
  type        = string
}

variable "subdomain" {
  description = "The delegated DNS subdomain the team controls (e.g. grupo7.oyd.solid.com.gt). A public Route53 hosted zone for it must already exist (created in the bootstrap workspace) — this module looks it up via a data source."
  type        = string
}

variable "api_subdomain_label" {
  description = "Label prepended to the subdomain for the API Gateway custom domain (default 'api' -> api.<subdomain>). This endpoint binds the regional ACM certificate to the HTTP API."
  type        = string
  default     = "api"
}

variable "app_subdomain_label" {
  description = "Label prepended to the subdomain for the CloudFront endpoint (default 'app' -> app.<subdomain>). CloudFront serves the React SPA from a private S3 bucket and provides the HTTP->HTTPS 301 redirect that an HTTPS-only origin cannot."
  type        = string
  default     = "app"
}

variable "spa_bucket_name" {
  description = "Name of the private S3 bucket that stores the built React SPA. CloudFront reads it via an Origin Access Control; the bucket blocks all public access."
  type        = string
}

variable "api_id" {
  description = "Id of the API Gateway v2 HTTP API to attach the custom domain to (module.ingress.api_id)."
  type        = string
}

variable "api_stage_name" {
  description = "Name of the API Gateway stage the custom domain maps to. The HTTP API uses the auto-deployed default stage."
  type        = string
  default     = "$default"
}

variable "ssl_policy" {
  description = "TLS security policy for the API Gateway custom domain (minimum negotiated TLS version)."
  type        = string
  default     = "TLS_1_2"
}

variable "cloudfront_minimum_protocol_version" {
  description = "Minimum TLS version CloudFront negotiates with viewers."
  type        = string
  default     = "TLSv1.2_2021"
}

variable "viewer_protocol_policy" {
  description = "CloudFront viewer protocol policy. 'redirect-to-https' returns an HTTP 301 from port 80 to 443 for every request — the explicit, curl-verifiable HTTP->HTTPS redirect required by the deliverable."
  type        = string
  default     = "redirect-to-https"
}

variable "cloudfront_price_class" {
  description = "CloudFront price class. PriceClass_100 (US/Canada/Europe edges) is the cheapest and sufficient for the project."
  type        = string
  default     = "PriceClass_100"
}

variable "tags" {
  description = "Additional tags merged onto taggable resources. The module adds Environment, ManagedBy and Module tags automatically."
  type        = map(string)
  default     = {}
}

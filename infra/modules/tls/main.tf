locals {
  api_fqdn = "${var.api_subdomain_label}.${var.subdomain}"
  app_fqdn = "${var.app_subdomain_label}.${var.subdomain}"

  module_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "tls"
  })
}

# The delegated public hosted zone, created in the bootstrap workspace so it
# survives `terraform destroy` on this (main) workspace and the name servers
# stay stable for the instructor's delegation.
data "aws_route53_zone" "this" {
  name         = var.subdomain
  private_zone = false
}

# Managed CloudFront policies: never cache the API and forward everything
# EXCEPT the viewer Host header (the origin — the API Gateway custom domain —
# must receive its own hostname so it can route the request).
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# ===========================================================================
# ACM certificate — one wildcard cert (regional, in this account's region)
# covering both api.<subdomain> and app.<subdomain>. Validated via DNS records
# written into the delegated zone.
# ===========================================================================
resource "aws_acm_certificate" "this" {
  domain_name               = var.subdomain
  subject_alternative_names = ["*.${var.subdomain}"]
  validation_method         = "DNS"

  tags = local.module_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# ===========================================================================
# API Gateway custom domain (regional) — binds the validated cert to the HTTP
# API. This is the serverless-track requirement: a custom domain, not the
# auto-generated *.execute-api URL.
# ===========================================================================
resource "aws_apigatewayv2_domain_name" "api" {
  domain_name = local.api_fqdn

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.this.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = var.ssl_policy
  }

  tags = local.module_tags
}

resource "aws_apigatewayv2_api_mapping" "api" {
  api_id      = var.api_id
  domain_name = aws_apigatewayv2_domain_name.api.id
  stage       = var.api_stage_name
}

# Alias record: api.<subdomain> -> the regional API Gateway custom domain.
resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.api_fqdn
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# ===========================================================================
# CloudFront distribution — fronts the API at app.<subdomain> with
# viewer_protocol_policy = redirect-to-https, providing the explicit HTTP 301
# (port 80 -> 443) that an HTTPS-only API Gateway custom domain cannot. Uses
# the same wildcard ACM cert (CloudFront requires us-east-1, which is this
# project's region, so the regional cert is also valid for CloudFront).
# ===========================================================================
resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "TicketResolve ${var.environment} - HTTPS + HTTP->HTTPS 301 in front of the API."
  aliases         = [local.app_fqdn]
  price_class     = var.cloudfront_price_class
  is_ipv6_enabled = true

  origin {
    domain_name = aws_apigatewayv2_domain_name.api.domain_name
    origin_id   = "apigw-custom-domain"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "apigw-custom-domain"
    viewer_protocol_policy   = var.viewer_protocol_policy
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = var.cloudfront_minimum_protocol_version
  }

  tags = local.module_tags

  depends_on = [aws_route53_record.api]
}

# Alias record: app.<subdomain> -> the CloudFront distribution.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

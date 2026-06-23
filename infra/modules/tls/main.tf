data "aws_region" "current" {}

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

    # CloudFront requires its viewer certificate in us-east-1. Since the same
    # cert also serves the regional API Gateway custom domain, the whole module
    # only works when the workspace region is us-east-1 — fail fast at plan time
    # if that ever changes, instead of with an opaque error at apply.
    precondition {
      condition     = data.aws_region.current.name == "us-east-1"
      error_message = "module.tls requires region us-east-1 (CloudFront viewer certificates must live there). Set var.region = \"us-east-1\" or disable enable_tls."
    }
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
# SPA hosting — a private S3 bucket holding the built React app, served by
# CloudFront via an Origin Access Control (OAC). The bucket blocks all public
# access; only this distribution can read it. The SPA calls the API directly at
# api.<subdomain>, so CloudFront only serves static assets here.
# ===========================================================================
resource "aws_s3_bucket" "spa" {
  bucket        = var.spa_bucket_name
  force_destroy = true
  tags          = local.module_tags
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket                  = aws_s3_bucket.spa.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "spa" {
  name                              = "${var.environment}-ticketresolve-spa-oac"
  description                       = "OAC for the TicketResolve SPA bucket."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Cache static assets aggressively; the deploy invalidates the distribution so a
# new build is served immediately despite caching.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# ===========================================================================
# CloudFront distribution — serves the SPA at app.<subdomain> from the private
# S3 bucket (OAC), with viewer_protocol_policy = redirect-to-https for the
# explicit HTTP 301 (port 80 -> 443). SPA client-side routing is supported by
# mapping 403/404 to /index.html. Uses the same wildcard ACM cert (CloudFront
# requires us-east-1, which is this project's region).
# ===========================================================================
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "TicketResolve ${var.environment} - SPA over HTTPS (HTTP->HTTPS 301)."
  aliases             = [local.app_fqdn]
  price_class         = var.cloudfront_price_class
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.spa.bucket_regional_domain_name
    origin_id                = "spa-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.spa.id
  }

  default_cache_behavior {
    target_origin_id       = "spa-s3"
    viewer_protocol_policy = var.viewer_protocol_policy
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  # Single-page app: any unmatched path returns index.html so client-side
  # routing works and a deep-link refresh does not 404.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
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
}

# Bucket policy: allow ONLY this CloudFront distribution (via OAC) to read.
data "aws_iam_policy_document" "spa_bucket" {
  statement {
    sid       = "AllowCloudFrontOACRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.spa.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "spa" {
  bucket = aws_s3_bucket.spa.id
  policy = data.aws_iam_policy_document.spa_bucket.json
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

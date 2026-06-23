data "aws_caller_identity" "current" {}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  state_bucket_name = "${var.project_name}-tfstate-${local.account_id}"
  lock_table_name   = "${var.project_name}-tflock"
  common_tags = {
    Project   = var.project_name
    Component = "tfstate-backend"
    ManagedBy = "Terraform"
    Workspace = "bootstrap"
  }
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  tags = merge(local.common_tags, {
    Name = local.state_bucket_name
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = local.lock_table_name
  })

  lifecycle {
    prevent_destroy = true
  }
}

# ===========================================================================
# Delegated DNS zone for TLS (Delivery 5, Deliverable D).
# Lives in the bootstrap workspace — NOT the main workspace — so it survives
# `terraform destroy` on main. That keeps the four name servers stable: the
# instructor delegates grupo7.oyd.solid.com.gt to these NS ONCE, and the
# one-click destroy/re-apply cycle on the main workspace never invalidates the
# delegation (recreating the zone would assign new NS and break it).
# After `terraform apply` here, send var.dns_subdomain + the name_servers
# output to the instructor.
# ===========================================================================
resource "aws_route53_zone" "delegated" {
  name    = var.dns_subdomain
  comment = "TicketResolve delegated subdomain for Delivery 5 TLS. NS delegated from the parent oyd.solid.com.gt by the instructor."

  tags = merge(local.common_tags, {
    Name      = var.dns_subdomain
    Component = "dns"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# ===========================================================================
# GitHub Actions OIDC provider + CI runner role (Delivery 5, Deliverable C).
# These are CI PREREQUISITES: the CD pipeline assumes the ci_runner role via
# OIDC, so the provider and role must exist BEFORE any pipeline run. They live
# in the bootstrap workspace (not the main workspace) so a `terraform destroy`
# on main never removes them — otherwise the very next clean-state CD run could
# not authenticate. Same rationale as the state backend and the DNS zone.
# Trust is scoped to this repo's exact subject claims (no wildcard subject).
# ===========================================================================
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = merge(local.common_tags, { Component = "oidc" })
}

data "aws_iam_policy_document" "ci_runner_assume" {
  statement {
    sid     = "GitHubOIDCAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.allowed_oidc_subjects
    }
  }
}

resource "aws_iam_role" "ci_runner" {
  name               = "${var.project_name}-ci-runner"
  description        = "GitHub Actions CI runner role assumed via OIDC. Grants terraform plan/apply across all modules. Trust scoped to this repo's main branch + dev/staging environments only."
  assume_role_policy = data.aws_iam_policy_document.ci_runner_assume.json

  tags = merge(local.common_tags, { Component = "oidc" })
}

# Deploy permissions. A CI/CD role that runs `terraform apply` must create
# resources that do not exist yet, so Resource is "*"; Actions are enumerated
# per service (no "*" action) and the role is assumable ONLY from this repo.
data "aws_iam_policy_document" "ci_runner" {
  statement {
    sid    = "ProvisionProjectResources"
    effect = "Allow"
    actions = [
      "s3:*", "dynamodb:*", "lambda:*", "apigateway:*", "logs:*",
      "iam:*", "kms:*", "secretsmanager:*", "sns:*", "sqs:*",
      "scheduler:*", "cloudwatch:*", "budgets:*", "route53:*",
      "acm:*", "cloudfront:*",
      # ec2:* (not just Describe) — the network module CREATES the VPC, subnets,
      # IGW, route tables, security groups, NACLs and gateway endpoints.
      "ec2:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ci_runner" {
  name        = "${var.project_name}-ci-runner"
  description = "Permissions for the GitHub Actions CI runner to plan/apply all project modules."
  policy      = data.aws_iam_policy_document.ci_runner.json
}

resource "aws_iam_role_policy_attachment" "ci_runner" {
  role       = aws_iam_role.ci_runner.name
  policy_arn = aws_iam_policy.ci_runner.arn
}

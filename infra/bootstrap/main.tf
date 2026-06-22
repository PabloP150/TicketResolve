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

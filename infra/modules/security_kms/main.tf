locals {
  alias = coalesce(var.alias_name, "${var.project_name}-${var.environment}")

  module_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "security_kms"
  })

  # Services allowed to use the CMK on behalf of a caller in THIS account.
  # The kms:ViaService condition guarantees the key can only be exercised
  # through these managed services — never by a raw principal directly.
  via_services = [
    "s3.${var.region}.amazonaws.com",
    "dynamodb.${var.region}.amazonaws.com",
    "secretsmanager.${var.region}.amazonaws.com",
  ]
}

# ===========================================================================
# Customer-managed KMS key (CMK). Encrypts the S3 buckets, the DynamoDB table
# and the Secrets Manager secret below. The key policy is least-privilege:
#   * administration is restricted to specific principals (deployer + CI role)
#     via an aws:PrincipalArn condition — NOT root-without-condition;
#   * usage is restricted to the S3 / DynamoDB / Secrets Manager services in
#     this account via a kms:ViaService + kms:CallerAccount condition.
# No statement grants kms:* or kms:Decrypt to all principals.
# ===========================================================================
data "aws_iam_policy_document" "cmk" {
  # --- Administration: only the named principals may manage the key ---------
  statement {
    sid    = "KeyAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]

    resources = ["*"]

    # Root is the Principal so the policy is always valid, but the condition
    # narrows the effective grant to exactly the deployer and the CI role.
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalArn"
      values   = var.key_admin_principal_arns
    }
  }

  # --- Usage: only the encrypting AWS services in this account --------------
  statement {
    sid    = "AllowUseThroughAWSServices"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = local.via_services
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_kms_key" "cmk" {
  description             = "TicketResolve ${var.environment} CMK - encrypts S3 buckets, the DynamoDB table and the Secrets Manager DB password secret."
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  policy                  = data.aws_iam_policy_document.cmk.json
  tags                    = local.module_tags
}

resource "aws_kms_alias" "cmk" {
  name          = "alias/${local.alias}"
  target_key_id = aws_kms_key.cmk.key_id
}

# ===========================================================================
# Secrets Manager — the database password, encrypted with the CMK above.
# The value comes from the sensitive var.db_password (never a committed
# .tfvars). The compute handler reads it at runtime via GetSecretValue using
# the ARN injected as an environment variable — replacing the old
# TF_VAR_db_password env-var-injection pattern from Delivery 3/4.
# ===========================================================================
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}-${var.environment}-db-password"
  description             = "TicketResolve ${var.environment} database password. Read at runtime by the compute layer via GetSecretValue; encrypted with the project CMK."
  kms_key_id              = aws_kms_key.cmk.arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = local.module_tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password

  # Terraform SEEDS the secret with the value from the sensitive variable, but
  # the authoritative value is then managed inside Secrets Manager (rotated /
  # updated via the console or CLI). ignore_changes lets the real credential
  # live only in Secrets Manager — so the TF_VAR_db_password GitHub secret can
  # be retired and the plaintext never has to flow through CI again.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

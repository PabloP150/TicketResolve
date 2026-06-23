output "kms_key_arn" {
  description = "ARN of the customer-managed CMK. Consumed by the storage and database modules to enable aws:kms encryption, and by the IAM module to scope kms:Decrypt on the async consumer role."
  value       = aws_kms_key.cmk.arn
}

output "kms_key_id" {
  description = "Key id of the CMK. Useful for aws kms describe-key / get-key-policy evidence commands."
  value       = aws_kms_key.cmk.key_id
}

output "kms_alias_name" {
  description = "Friendly alias of the CMK (alias/<name>). Surfaced for evidence (aws kms describe-key --key-id alias/<name>)."
  value       = aws_kms_alias.cmk.name
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB password. Injected (the ARN, not the value) into the compute layer as DB_SECRET_ARN and scoped on the async consumer role's secretsmanager:GetSecretValue statement."
  value       = aws_secretsmanager_secret.db_password.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret. Useful for aws secretsmanager describe-secret evidence."
  value       = aws_secretsmanager_secret.db_password.name
}

# Bootstrap Workspace

This **isolated** Terraform workspace provisions the two long-lived resources that the **main** workspace uses as its remote state backend:

- An S3 bucket for the state file (`terraform.tfstate`).
- A DynamoDB table for distributed state locking.

## Why a separate workspace?

The S3 bucket and lock table that hold a state file cannot themselves live inside that same state file — a `terraform destroy` on the main workspace would otherwise tear down the very infrastructure that backs it. We resolve this by managing them in a dedicated workspace that **uses local state intentionally**:

- No `backend "s3"` block in this directory.
- `terraform.tfstate` for this workspace IS committed to the repository (it tracks two stable resources that are never recreated).
- Both resources carry `lifecycle { prevent_destroy = true }` — accidental destruction surfaces as a plan error, not a runtime event.

## How to apply (one-time, manual)

```bash
cd infra/bootstrap
terraform init
terraform apply
terraform output    # copy state_bucket_name and lock_table_name into infra/backend.tf
```

Once applied, the resulting `terraform.tfstate` (and `terraform.tfstate.backup`) must be committed alongside this directory's `.tf` files. The `.gitignore` at the repository root has explicit re-include rules for these two paths.

## What to do next

After this workspace is applied:

1. Edit `infra/backend.tf` with the hardcoded `state_bucket_name`, `lock_table_name` and `region` values shown by `terraform output`. Backend blocks cannot reference variables, so the values must be literal strings.
2. `cd ../` and run `terraform init` — Terraform will detect the new backend block and prompt to copy any local state into the remote bucket.

## Outputs

| Output | Description |
| ------ | ----------- |
| `state_bucket_name` | Name of the state bucket. Hardcode into `infra/backend.tf`. |
| `lock_table_name`  | Name of the lock table. Hardcode into `infra/backend.tf`. |
| `region`           | Region. Hardcode into `infra/backend.tf`. |
| `state_bucket_arn` | ARN of the state bucket (for IAM references in later deliveries). |
| `lock_table_arn`   | ARN of the lock table (for IAM references in later deliveries). |

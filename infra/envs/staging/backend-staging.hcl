# Remote-state backend key for the staging environment (Delivery 4 — Pattern A).
# Separate key => separate state file from dev in the same bucket.
# Used as: terraform init -backend-config=envs/staging/backend-staging.hcl
key = "env/staging/terraform.tfstate"

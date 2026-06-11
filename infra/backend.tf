terraform {
  # Partial backend configuration (Delivery 4 — Pattern A: separate backend
  # configs per environment). The bucket, region, lock table and encryption are
  # fixed for the whole project; the per-environment state `key` is supplied at
  # init time via -backend-config=envs/<env>/backend-<env>.hcl so dev and
  # staging never share a state file.
  #
  #   terraform init -backend-config=envs/dev/backend-dev.hcl
  #   terraform init -backend-config=envs/staging/backend-staging.hcl
  #
  # These literal values are the outputs of `terraform output` in infra/bootstrap/.
  backend "s3" {
    bucket         = "ticketresolve-tfstate-010526283195"
    region         = "us-east-1"
    dynamodb_table = "ticketresolve-tflock"
    encrypt        = true
  }
}

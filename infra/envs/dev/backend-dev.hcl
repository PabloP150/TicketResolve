# Remote-state backend key for the dev environment (Delivery 4 — Pattern A).
# The key includes the environment name so dev and staging never collide.
# Used as: terraform init -backend-config=envs/dev/backend-dev.hcl
key = "env/dev/terraform.tfstate"

terraform {
  # Backend blocks cannot reference variables or locals (Terraform language constraint).
  # The bucket, table and region values below are the literal outputs of
  # `terraform output` in infra/bootstrap/ on first apply.
  backend "s3" {
    bucket         = "ticketresolve-tfstate-010526283195"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ticketresolve-tflock"
    encrypt        = true
  }
}

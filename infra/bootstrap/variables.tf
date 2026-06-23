variable "region" {
  description = "AWS region where the state bucket and lock table live."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project identifier used as the prefix for the state bucket and the lock table names."
  type        = string
  default     = "ticketresolve"
}

variable "dns_subdomain" {
  description = "Delegated DNS subdomain the team controls for TLS (Delivery 5). A Route53 public hosted zone is created for it here in bootstrap; its name servers are sent to the instructor to delegate from the parent zone."
  type        = string
  default     = "grupo7.oyd.solid.com.gt"
}

variable "github_oidc_thumbprints" {
  description = "TLS thumbprints of the GitHub OIDC issuer. AWS validates token.actions.githubusercontent.com against its own trust store, but the provider resource still requires a thumbprint list."
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

variable "allowed_oidc_subjects" {
  description = "Exact GitHub OIDC subject claims allowed to assume the CI runner role (StringEquals, no wildcard). Main branch ref plus the dev/staging environment subjects used by the workflows."
  type        = list(string)
  default = [
    "repo:PabloP150/TicketResolve:ref:refs/heads/main",
    "repo:PabloP150/TicketResolve:environment:dev",
    "repo:PabloP150/TicketResolve:environment:staging",
  ]
}

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

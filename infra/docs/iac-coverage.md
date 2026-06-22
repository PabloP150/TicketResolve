# IaC Coverage Proof — Delivery 5 (Deliverable I)

This document proves that **every** cloud resource used by TicketResolve is
managed by Terraform. There are no manually created resources, no configuration
drift between the codebase and the live environment, and no component that lives
outside the Terraform state.

> This file is intentionally separate from the written summary
> (`infra/docs/delivery-5-summary.md`). Do not merge them.

## 1. Component-to-IaC mapping

Every running component appears as a row, covering all seven required component
categories: **compute, storage, database, networking, async, security/IAM, and
observability**.

| Application Component | Cloud Service Used | Terraform Resource Type | Module Path |
| --- | --- | --- | --- |
| **Compute** | | | |
| api-tickets Lambda (public API handler) | AWS Lambda | `aws_lambda_function` | `infra/modules/compute` (call `lambda_api_tickets`) |
| webhook-ingesta Lambda | AWS Lambda | `aws_lambda_function` | `infra/modules/compute` (call `lambda_webhook_ingesta`) |
| escalamiento Lambda (SLA sweep) | AWS Lambda | `aws_lambda_function` | `infra/modules/compute` (call `lambda_escalamiento`) |
| notificacion Lambda (async consumer) | AWS Lambda | `aws_lambda_function` | `infra/modules/compute` (call `lambda_notificacion`) |
| reporte-pdf Lambda | AWS Lambda | `aws_lambda_function` | `infra/modules/compute` (call `lambda_reporte_pdf`) |
| **Storage** | | | |
| Attachments bucket | Amazon S3 | `aws_s3_bucket` (+ versioning, SSE-KMS, lifecycle, public-access-block, SSL-only policy) | `infra/modules/storage` (call `attachments_bucket`) |
| Reports bucket | Amazon S3 | `aws_s3_bucket` (+ versioning, SSE-KMS, lifecycle, public-access-block, SSL-only policy) | `infra/modules/storage` (call `reports_bucket`) |
| **Database** | | | |
| Single-table data store | Amazon DynamoDB | `aws_dynamodb_table` (GSI1, GSI2, stream, SSE with CMK) | `infra/modules/database` |
| E2E seed item | DynamoDB item | `aws_dynamodb_table_item` | `infra/main.tf` |
| **Networking** | | | |
| VPC + subnets (public/app/data ×2 AZ) | Amazon VPC | `aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_route_table*`, gateway endpoints | `infra/modules/network` |
| Tiered security groups + NACLs | VPC security | `aws_security_group`, `aws_network_acl*` | `infra/modules/security` |
| Public HTTP API (ingress) | Amazon API Gateway v2 | `aws_apigatewayv2_api`, `_integration`, `_route`, `_stage`, `aws_lambda_permission` | `infra/modules/ingress` |
| TLS certificate | AWS Certificate Manager | `aws_acm_certificate`, `aws_acm_certificate_validation` | `infra/modules/tls` |
| API custom domain (HTTPS) | API Gateway custom domain | `aws_apigatewayv2_domain_name`, `aws_apigatewayv2_api_mapping` | `infra/modules/tls` |
| CDN + HTTP→HTTPS 301 | Amazon CloudFront | `aws_cloudfront_distribution` | `infra/modules/tls` |
| DNS records (validation + aliases) | Amazon Route 53 | `aws_route53_record` | `infra/modules/tls` |
| Delegated DNS zone | Amazon Route 53 | `aws_route53_zone` | `infra/bootstrap` (persistent workspace) |
| **Async** | | | |
| Events queue | Amazon SQS | `aws_sqs_queue` (+ redrive policy) | `infra/modules/async` |
| Dead-letter queue | Amazon SQS | `aws_sqs_queue` (+ redrive-allow policy) | `infra/modules/async` |
| Queue → consumer trigger | Lambda event source mapping | `aws_lambda_event_source_mapping` | `infra/main.tf` |
| Scheduled SLA sweep | Amazon EventBridge Scheduler | `aws_scheduler_schedule` | `infra/modules/scheduler` |
| **Security / IAM** | | | |
| Per-service execution roles (×6) | AWS IAM | `aws_iam_role` + `aws_iam_policy` + `aws_iam_role_policy_attachment` | `infra/modules/iam` |
| CI runner role (OIDC-assumable) | AWS IAM | `aws_iam_role` + `aws_iam_policy` | `infra/modules/iam` |
| GitHub Actions OIDC provider | AWS IAM | `aws_iam_openid_connect_provider` | `infra/modules/iam` |
| Customer-managed key (CMK) | AWS KMS | `aws_kms_key`, `aws_kms_alias` | `infra/modules/security_kms` |
| DB password secret | AWS Secrets Manager | `aws_secretsmanager_secret`, `_version` | `infra/modules/security_kms` |
| **Observability** | | | |
| Per-Lambda log groups (×5) | Amazon CloudWatch Logs | `aws_cloudwatch_log_group` | `infra/modules/observability` |
| Metric alarms (Lambda errors ×5, API 5xx, DLQ depth) | Amazon CloudWatch | `aws_cloudwatch_metric_alarm` | `infra/modules/observability` |
| Notification channel | Amazon SNS | `aws_sns_topic`, `_subscription`, `_policy` | `infra/modules/observability` |
| Dashboard | CloudWatch Dashboards | `aws_cloudwatch_dashboard` | `infra/modules/observability` |
| Cost budget | AWS Budgets | `aws_budgets_budget` | `infra/modules/observability` |
| **State backend (bootstrap)** | | | |
| Remote state bucket | Amazon S3 | `aws_s3_bucket` | `infra/bootstrap` |
| State lock table | Amazon DynamoDB | `aws_dynamodb_table` | `infra/bootstrap` |

## 2. Terraform state audit

The complete output of `terraform state list` (run from `infra/`) is committed
at [`infra/evidence/state-list.txt`](../evidence/state-list.txt). It contains at
least one resource from each of the seven required categories. Any resource
visible in the cloud console that does not appear in that list would represent a
manually created resource — there are none.

## 3. No manual resources

**The team confirms that no resources were created manually through the AWS
console.** Every resource was created by `terraform apply`. No `terraform import`
was used in this delivery; no resource was created out-of-band and later
imported. The only resources that exist outside the main workspace's state are
the bootstrap workspace resources (the remote-state S3 bucket, the DynamoDB lock
table, and the delegated Route 53 zone), which are themselves Terraform-managed
in `infra/bootstrap/` and intentionally kept separate so the main workspace can
be destroyed and re-applied without losing the state backend or the DNS
delegation.

## 4. Deployed application evidence

A console screenshot of the running components (the Lambda functions list in a
running/active state) is committed at
[`infra/evidence/deployed-components.png`](../evidence/deployed-components.png).

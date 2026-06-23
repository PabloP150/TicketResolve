# Delivery 5 — Security, Observability & One-Click Deployment (Written Summary)

**Team:** Grupo 7 · **Track:** Serverless (Lambda + API Gateway) · **Cloud:** AWS
us-east-1 · **Tag:** `oyd-delivery-5`

> The component-to-IaC coverage mapping is in the separate file
> [`infra/docs/iac-coverage.md`](./iac-coverage.md) (Deliverable I).

---

## 1. IAM and secrets design

### IAM module role structure

All ad-hoc execution roles that previously lived inside the `compute` and
`scheduler` modules were replaced by a single central module,
[`infra/modules/iam/`](../modules/iam), with one explicitly scoped role per
service. **No service role uses a wildcard Action or Resource.** Each role is an
`aws_iam_role` + managed `aws_iam_policy` + `aws_iam_role_policy_attachment`, so
every policy ARN is exposed as a module output.

| Role | Actions (scoped to the named resource ARNs) |
| --- | --- |
| `ticketresolve-dev-compute-api` (api-tickets) | `dynamodb:{GetItem,BatchGetItem,Query,Scan,ConditionCheckItem,PutItem,UpdateItem,DeleteItem,BatchWriteItem}` on the table + GSI1 + GSI2; `s3:{GetObject,PutObject,DeleteObject}` on the attachments bucket objects; `s3:ListBucket` on the bucket; `sqs:{SendMessage,GetQueueAttributes}` on the events queue; `logs:{CreateLogStream,PutLogEvents}` on its own log group |
| `ticketresolve-dev-compute-webhook` | DynamoDB read/write on the table + GSIs; own logs |
| `ticketresolve-dev-compute-escalamiento` | DynamoDB read/write on the table + GSIs; own logs |
| `ticketresolve-dev-async-consumer` (notificacion) | `sqs:{ReceiveMessage,DeleteMessage,GetQueueAttributes}` on the queue; `s3:PutObject` on the attachments objects; `secretsmanager:GetSecretValue` on the DB-password secret; `kms:Decrypt` on the CMK; own logs |
| `ticketresolve-dev-compute-reporte` | DynamoDB **read-only** on the table + GSIs; `s3:PutObject` on the reports objects; own logs |
| `ticketresolve-dev-scheduler-invoke` | `lambda:InvokeFunction` on **only** the escalamiento function ARN |
| `ticketresolve-dev-ci-runner` | OIDC-assumable; per-service actions for `terraform plan/apply` (see §3) |

**What changed:** previously each Lambda's role was generated inside the
`compute` module from an `additional_iam_statements` list passed at the call
site. Now `compute` receives only an `execution_role_arn` input; the role and its
least-privilege policy are defined once in the `iam` module and consumed by the
module calls in `infra/main.tf`. No role ARN is hardcoded — each is wired from a
module output. Construction of each role's own log-group ARN
(`arn:aws:logs:<region>:<account>:log-group:/aws/lambda/<fn>:*`) is done from the
function name string, which deliberately breaks the dependency cycle that would
otherwise exist between the role and the Lambda.

### Secrets Manager runtime retrieval

The database password was moved out of the `TF_VAR_db_password` →
`DB_PASSWORD` environment-variable injection used in Delivery 3/4. Now:

- Terraform stores the password in **AWS Secrets Manager**
  (`aws_secretsmanager_secret` + `_version`, value from the sensitive
  `var.db_password`, encrypted with the project CMK).
- Terraform injects only the **secret ARN** as the `DB_SECRET_ARN` environment
  variable on the notificacion Lambda — never the value.
- The handler ([`infra/lambda_src/notificacion/lambda_function.py`](../lambda_src/notificacion/lambda_function.py))
  calls **`secretsmanager:GetSecretValue`** (boto3) at cold start, caches the
  result for the container lifetime, and never logs the value (only its length).
- `TF_VAR_db_password` was removed from every workflow. The secret version uses
  `ignore_changes = [secret_string]`, so the authoritative value is managed
  inside Secrets Manager and the plaintext never has to flow through CI again.

**Why retired:** a plaintext password baked into a Lambda environment variable is
visible to anyone with `lambda:GetFunctionConfiguration` and is captured in the
Terraform state/plan. Fetching it at runtime via GetSecretValue keeps the secret
encrypted at rest under a CMK and gated by an explicit IAM grant.

---

## 2. KMS key management

A single customer-managed key (CMK) is created in
[`infra/modules/security_kms/`](../modules/security_kms):

- **Alias:** `alias/ticketresolve-dev`
- **Key ARN:** `arn:aws:kms:us-east-1:010526283195:key/8da89dc4-6ad3-445f-8382-fc04637cdd35`
- **Encrypts:** both S3 buckets (server-side encryption upgraded from SSE-S3
  `AES256` to `aws:kms` with bucket keys enabled), the DynamoDB table
  (`server_side_encryption.kms_key_arn`), and the Secrets Manager secret.
- **Key rotation:** enabled (yearly).

**Key policy (least-privilege, no broad grants):**

- *Administration* — principal is the account root **but constrained** by a
  `aws:PrincipalArn` condition listing exactly the human deployer and the CI
  runner role. The bare-root-without-condition pattern the rubric forbids is not
  used.
- *Usage* — principal is the account root **but constrained** by
  `kms:ViaService` ∈ {`s3.us-east-1.amazonaws.com`,
  `dynamodb.us-east-1.amazonaws.com`, `secretsmanager.us-east-1.amazonaws.com`}
  **and** `kms:CallerAccount = <account id>`. The key can therefore only be
  exercised through those three managed services, by callers inside this account
  — never granted to all principals.

This split (root-with-condition rather than naming each role) is what lets the
`iam` module depend on the `security_kms` outputs without a circular dependency.

---

## 3. OIDC federation

The GitHub Actions OIDC provider is provisioned as Terraform
(`aws_iam_openid_connect_provider`). It and the CI runner role live in the
**bootstrap** workspace, not the main workspace: the CD pipeline assumes the CI
runner role via OIDC, so both must survive a `terraform destroy` on main —
otherwise the next clean-state CD run could not authenticate (same rationale as
the state backend and the DNS zone):

- **Issuer URL:** `https://token.actions.githubusercontent.com`
- **Audience claim:** `sts.amazonaws.com`
- **Subject claim condition (StringEquals, no wildcard):**
  `repo:PabloP150/TicketResolve:ref:refs/heads/main`,
  `repo:PabloP150/TicketResolve:environment:dev`, and
  `repo:PabloP150/TicketResolve:environment:staging`. A PR from a fork (subject
  `repo:.../pull_request` or any other repo) cannot assume the role.
- **CI runner role ARN:** `arn:aws:iam::010526283195:role/ticketresolve-ci-runner` (in the bootstrap workspace)
- **OIDC provider ARN:** `arn:aws:iam::010526283195:oidc-provider/token.actions.githubusercontent.com`

**Workflow changes:** every workflow that runs `terraform plan/apply/destroy`
(`terraform-ci.yml`, `terraform-apply.yml`, `terraform-destroy.yml`,
`terraform-drift.yml`) now declares `permissions: id-token: write` and uses
`aws-actions/configure-aws-credentials@v4` with `role-to-assume:
${{ vars.AWS_CI_ROLE_ARN }}` (the ARN comes from a GitHub Actions variable set
from the Terraform output — not hardcoded in YAML). The
`aws-access-key-id`/`aws-secret-access-key` inputs were removed.

**Credential removal:** the long-lived `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` repository secrets were deleted after OIDC was validated
(evidence: `infra/evidence/oidc-secrets-removed.png`). `TF_VAR_db_password`
(`DEV_DB_PASSWORD` / `STAGING_DB_PASSWORD`) was likewise retired.

---

## 4. Observability design

Module [`infra/modules/observability/`](../modules/observability), called from
root with every input wired from variables.

**Alarms (all thresholds are variables):**

| Alarm | Metric | Threshold | Why |
| --- | --- | --- | --- |
| `<fn>-errors` (one per Lambda) | `AWS/Lambda Errors` (Sum) | `>= 1` in 300s | Low-traffic academic workload — every Lambda error is worth surfacing immediately rather than waiting for a rate to build. |
| `ticketresolve-dev-apigw-5xx` | `AWS/ApiGateway 5xx` (Sum) | `>= 1` in 300s | A 5xx means the backend failed; a low threshold catches regressions on the first occurrence. |
| `ticketresolve-dev-dlq-depth` | `AWS/SQS ApproximateNumberOfMessagesVisible` on the DLQ (Max) | `>= 1` | Any message in the DLQ means a record exhausted its retries and needs investigation. |

All alarms notify a single **SNS topic** with an **email** subscription
(`alarm_notification_email`).

**Dashboard** (`aws_cloudwatch_dashboard`, body built with `jsonencode()` — no
hardcoded metric names/ARNs in a heredoc) has three widgets: (1) API Gateway
request count (ingress traffic), (2) Lambda errors by function (compute error
rate), and (3) SQS queue vs DLQ depth (async health).

**Cost budget** (`aws_budgets_budget`): **$5/month** (`var.monthly_budget_usd`)
with a notification at **80%** routed to the same SNS topic. The project targets
near-$0, so a small cap makes any unexpected spend (e.g. a forgotten NAT
gateway) visible immediately.

---

## 5. Two architectural trade-offs

### Trade-off A — CloudFront in front of API Gateway for the HTTP→HTTPS 301

An API Gateway v2 HTTP API custom domain is **HTTPS-only**: there is no port-80
listener to issue a redirect, so `curl http://...` against it simply refuses the
connection rather than returning the `301` the deliverable requires. We
therefore serve the public site through a **CloudFront distribution**
(`app.grupo7.oyd.solid.com.gt`) with `viewer_protocol_policy =
redirect-to-https`, which returns an explicit, curl-verifiable `301` from port 80
to 443. We *also* keep the `aws_apigatewayv2_domain_name`
(`api.grupo7.oyd.solid.com.gt`) with the **regional** ACM certificate to satisfy
the serverless-track requirement literally (a certificate bound to an API Gateway
custom domain, not the auto-generated `*.execute-api` URL). The cost is a second
public endpoint and a CloudFront distribution; the benefit is that both the
"regional cert on API Gateway custom domain" clause and the "HTTP 301 redirect"
clause are fully satisfied. Because our region is us-east-1, one ACM certificate
serves both the regional API Gateway domain and CloudFront (which requires
us-east-1).

### Trade-off B — One shared CMK vs a per-service key

We provision a **single CMK** that encrypts the S3 buckets, the DynamoDB table
and the Secrets Manager secret, rather than one key per service. For a
near-$0 academic workload this minimizes cost (each CMK is ~$1/month) and key
sprawl while still meeting the requirement of customer-managed encryption with a
restrictive key policy. The downside is a coarser blast radius — rotating or
disabling the key affects all three data stores at once, and the key policy must
enumerate every consuming service in its `kms:ViaService` condition. A production
system handling regulated data would likely split into per-domain keys
(e.g. a separate key for the secret) to get independent rotation schedules and
finer-grained revocation; we judged that unnecessary for this project and
explicitly chose the shared key.

---

## Public endpoints (TLS coverage)

Both public-facing URLs are covered by the same wildcard ACM certificate:

| URL | Serves | TLS |
| --- | --- | --- |
| `https://api.grupo7.oyd.solid.com.gt` | API Gateway custom domain (regional cert) | HTTPS only (200) |
| `https://app.grupo7.oyd.solid.com.gt` | CloudFront → API Gateway | HTTPS (200) + HTTP `301` redirect |

**Domain source:** the team controls `grupo7.oyd.solid.com.gt`, a subdomain
delegated by the instructor. A Route 53 public hosted zone for it is created in
the bootstrap workspace; its name servers were sent to the instructor, who
delegated the subdomain from the parent `oyd.solid.com.gt` zone. ACM DNS
validation and all alias records are managed in Terraform.

## Deployment bot (Deliverable J)

The Slack `/deploy <environment>` bot lives in a separate repository:
**https://github.com/PabloP150/ticketresolve-deploy-bot**. It triggers this
repo's `terraform-apply.yml` via the GitHub `workflow_dispatch` API, validates
the environment (rejecting unknown names), and replies with the environment, the
run URL and the timestamp. See its README for setup and the required secrets
(`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `GITHUB_TOKEN`).

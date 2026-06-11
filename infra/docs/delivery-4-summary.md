# Delivery 4 — Async Infrastructure & Full CD Pipeline (Summary)

**Project:** TicketResolve · **Track:** VPC-required (AWS) · **Provider:** AWS · **IaC:** Terraform ~> 1.8
**Account/region:** `010526283195` / `us-east-1`

This document addresses the six required points. Every value cited matches the
committed Terraform and the live `dev` environment that was applied for this
delivery.

---

## 1. Async messaging design

**Service chosen: Amazon SQS, standard queue** (`infra/modules/async/`). One main
queue `ticketresolve-dev-events` and a dedicated dead-letter queue
`ticketresolve-dev-events-dlq`, wired with a `redrive_policy`.

- **DLQ configuration (dev):** `max_receive_count = 5` — a message that the
  consumer fails to delete after **5** receive attempts is moved to the DLQ
  rather than retried forever or silently dropped. Main-queue retention is
  `message_retention_seconds = 345600` (**4 days**); the DLQ keeps failures the
  full `dlq_message_retention_seconds = 1209600` (**14 days**) so an operator has
  more than a week to inspect and replay poison messages after the main queue
  would already have expired them. `visibility_timeout_seconds = 90` is larger
  than the consumer Lambda timeout (60 s) so a slow invocation cannot let SQS
  redeliver the same message mid-flight.
- **Why these values:** TicketResolve events (SLA breaches, alert fan-out) are
  low-volume and idempotent on the consumer side (the object key is derived from
  the SQS message id, so a re-delivery overwrites the same S3 object). Five
  attempts absorbs transient S3/throttling errors; four-day main retention is
  ample for a system whose consumer drains the queue in seconds; the 14-day DLQ
  is the SQS maximum and maximises the forensic window.
- **FIFO not required.** Ordering does not matter: each event is processed
  independently and written to its own keyed object, and the workload benefits
  from standard-queue throughput and the lower cost / higher limits of standard
  over FIFO. We therefore chose **SQS standard**, not FIFO.

Outputs exposed by the module: `queue_url`, `queue_arn`, `queue_name`, `dlq_url`,
`dlq_arn`. The module is consumed from the root (`module "events_queue"`) with
every input wired from root variables / `<env>.tfvars` — no hardcoded values.

## 2. Event-driven architecture

The compute target is the **`notificacion` Lambda** (the SQS consumer), connected
to the queue by an `aws_lambda_event_source_mapping`
(`infra/main.tf` → `events_to_notificacion`). Queue ARN and function ARN come
from module outputs — no hardcoded ARNs.

- **Mapping settings (variables, not literals):** `batch_size = 10`,
  `maximum_batching_window_in_seconds = 5`. Batching trades a few seconds of
  latency for far fewer Lambda invocations.
- **Failure isolation:** `bisect_batch_on_function_error` applies only to
  Kinesis/DynamoDB *stream* sources, so for SQS we use its real equivalent —
  **partial batch responses** (`function_response_types = ["ReportBatchItemFailures"]`,
  driven by `var.event_source_bisect_on_error`). The handler returns the failed
  `messageId`s in `batchItemFailures`; only those messages return to the queue,
  and after `max_receive_count` (5) they land in the DLQ. Good messages in the
  same batch are deleted and never re-failed.
- **Expected action on dead-lettered messages:** they accumulate in
  `ticketresolve-dev-events-dlq`; an operator inspects depth via
  `aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages`,
  fixes the root cause (bad payload / downstream outage) and replays them. A DLQ
  depth alarm is the natural Delivery-5 follow-up.
- **Concurrency bounding (caveat):** the design bounds the consumer with
  `reserved_concurrent_executions` (supported by the compute module). This AWS
  account is **unverified**, so its *total* concurrency limit is the floor of 10
  and AWS rejects any reservation that would drop unreserved below 10. The value
  is therefore left `null` in `dev`/`staging` and documented; the module accepts
  a numeric value the moment a limit increase is granted (e.g. prod).
- **IAM (least privilege):** the consumer role has exactly
  `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` on the
  **specific queue ARN** and `s3:PutObject` on the attachments bucket ARN. No
  wildcard resources (enforced by a validation in the compute module).

## 3. Terraform environment layout and CD pipeline

**Directory structure:** `infra/envs/dev/` and `infra/envs/staging/`, each with a
`*.tfvars` and a `backend-<env>.hcl`.

**State pattern — Pattern A (separate backend configs).** `infra/backend.tf` is a
*partial* S3 backend (fixed bucket/region/lock table); the per-environment state
**key** is injected at init time:
`terraform init -backend-config=envs/dev/backend-dev.hcl`. The keys include the
environment name — `env/dev/terraform.tfstate` and `env/staging/terraform.tfstate`
— so the two environments never share a state file. **Why Pattern A over
workspaces:** explicit, self-documenting state keys and a backend file per
environment make it obvious in CI exactly which state is targeted; there is no
hidden "current workspace" that a forgotten `workspace select` could silently
point at the wrong environment.

**At least three values differ** between `dev.tfvars` and `staging.tfvars`:

| Variable | dev | staging | Meaning |
| --- | --- | --- | --- |
| `vpc_cidr` (+ subnets) | `10.20.0.0/16` | `10.30.0.0/16` | Non-overlapping networks so the two environments could be peered/audited side by side. |
| `lambda_memory_default` | `256` | `512` | Staging mirrors a heavier pre-prod load profile. |
| `queue_message_retention_seconds` | `345600` (4 d) | `1209600` (14 d) | Staging keeps messages longer for pre-prod debugging. |
| `queue_max_receive_count` | `5` | `3` | Staging quarantines a poison message sooner to surface failures earlier. |
| `sla_sweep_schedule_expression` | `rate(1 day)` | `rate(12 hours)` | Staging sweeps SLAs twice as often. |

**Plan-artifact promotion flow:**
- *Plan-on-PR* (`terraform-ci.yml`): three independent jobs report distinct
  checks — `terraform fmt`, `terraform validate`, `terraform plan`. The plan job
  runs `terraform plan -out=tfplan`, uploads `tfplan` via `actions/upload-artifact`,
  and posts the plan as a PR comment.
- *CD on merge* (`terraform-apply.yml`): `plan-dev` runs `terraform plan -out=tfplan`
  and uploads the binary plan (plus the built Lambda zips); `apply-dev`
  **downloads that exact artifact** with `actions/download-artifact` and runs
  `terraform apply tfplan` — never `-auto-approve`, never a re-plan. What was
  reviewed is what applies.

**Staging approval gate:** the `apply-staging` job declares `environment: staging`.
The **staging GitHub Environment** has a required reviewer — **PabloP150** — so
the job pauses until that reviewer approves in the GitHub UI, then plans and
applies with `-var-file=envs/staging/staging.tfvars`. The `dev` Environment has
no reviewers and applies automatically.

**Secret namespacing:** sensitive values are **environment-scoped** GitHub
secrets, not repository secrets: `DEV_DB_PASSWORD` lives in the `dev`
Environment, `STAGING_DB_PASSWORD` in `staging`. Each is injected only into its
environment's jobs as `TF_VAR_db_password`; the Terraform variable is declared
`sensitive = true` and never written to any committed `.tfvars`.

**Branch protection ruleset on `main`** (Active): requires a pull request before
merging; requires the three status checks **`terraform fmt`, `terraform validate`,
`terraform plan`** to pass (names match the job names exactly, or the gate would
silently never fire); requires **branches to be up to date** before merging
(`strict` status-check policy) so a PR that fell behind `main` must rebase and
re-run its checks; **blocks force pushes** (`non_fast_forward`) and **blocks
deletion** of `main`. Requiring up-to-date branches plus blocking force pushes
means no one can rewrite history or merge a stale branch whose checks passed
against an older tree — every change reaches `main` only through a PR whose
checks ran against the current `main`.

## 4. Scheduled jobs

**Function:** the **`escalamiento` Lambda**, invoked as a periodic **SLA sweep**
(scan open tickets past their SLA). It is **distinct from the async consumer**
(`notificacion`), as required. Provisioned via `aws_scheduler_schedule`
(EventBridge Scheduler) in `infra/modules/scheduler/`.

- **Cron/cadence:** `rate(1 day)` in dev (`rate(12 hours)` in staging), time zone
  **`America/Guatemala`** so the cadence is deterministic regardless of the
  account default. Daily is enough because SLA breaches are reported in near-real
  time by the event path; the sweep is a backstop, not the primary detector.
- **IAM scope and why it is narrower than the compute role:** the scheduler
  assumes a **dedicated role** (`ticketresolve-dev-sla-sweep-invoke`) whose only
  permission is `lambda:InvokeFunction` on the **single** escalamiento function
  ARN — no wildcard. That is strictly narrower than escalamiento's own execution
  role, which can read/write DynamoDB: the scheduler may *invoke* the function
  but can never touch ticket data. Separating "who may trigger" from "what the
  triggered code may do" keeps the blast radius of the scheduler credential
  minimal.

## 5. End-to-end async proof

**Language/runtime:** Python 3.12 on AWS Lambda — the same runtime used for
Infraestructura en la Nube and D3.

**Flow (verified live in dev):**
1. **Enqueue:** `POST /api/v1/incidents/enqueue` on the D3 API Gateway ingress
   routes to the `api-tickets` Lambda, which calls `sqs:SendMessage` on the
   events queue and returns **HTTP 202** with the **real** SQS `MessageId`
   (e.g. `7e11f39f-7b54-4790-9f43-f2f19b31ec04`). The id is from SQS, not
   synthesized.
2. **Deliver:** the `aws_lambda_event_source_mapping` polls the queue and invokes
   the `notificacion` consumer with a batch of records.
3. **Consume:** the consumer reads each record and writes one object to the D2
   attachments bucket, key `events/<messageId>.json`, and logs the processed
   message id. Verified object:
   `s3://ticketresolve-attachments-dev-010526283195/events/7e11f39f-….json`;
   CloudWatch log: `processed message_id=7e11f39f-… -> s3://…`.

Both endpoints are reachable only through the D3 ingress (producer) and the event
source mapping (consumer) — never via a direct Lambda URL.

**IAM execution scope (no wildcards):**
- Producer (`api-tickets`): `sqs:SendMessage`, `sqs:GetQueueAttributes` on
  `arn:aws:sqs:us-east-1:010526283195:ticketresolve-dev-events` (plus its
  existing DynamoDB/S3 scopes).
- Consumer (`notificacion`): `sqs:ReceiveMessage`, `sqs:DeleteMessage`,
  `sqs:GetQueueAttributes` on the same queue ARN, and `s3:PutObject` on
  `arn:aws:s3:::ticketresolve-attachments-dev-010526283195/*`.

**Object key derivation:** the consumer uses the SQS `messageId` directly as the
key (`events/<messageId>.json`). This makes the write idempotent — a redelivered
message overwrites the same object instead of creating duplicates — and traces
each object back to its queue record.

**Non-sensitive config** (queue URL, bucket name, region) flows through
`var.* / dev.tfvars` and is injected as Lambda environment variables
(`QUEUE_URL`, `ATTACHMENTS_BUCKET`); the handlers read them from the process
environment at runtime. **Sensitive config** (`db_password`) is never committed —
it is the `TF_VAR_db_password` injected from the environment-scoped secret.

## 6. Two architectural trade-offs

**(a) SQS standard vs. FIFO.** We chose **standard**. FIFO guarantees exactly-once
ordering but caps throughput (300 msg/s without batching) and costs more.
TicketResolve events are order-independent and the consumer is idempotent (key =
message id), so ordering buys us nothing while standard gives higher limits and
lower cost. The risk standard carries — occasional duplicate delivery — is
neutralised by idempotent writes, so the cheaper, higher-throughput option is
strictly better for this workload.

**(b) Separate backend configs (Pattern A) vs. Terraform workspaces.** We chose
**separate `backend-<env>.hcl` files**. Workspaces keep one backend and switch an
internal name, which is terse but hides the active environment behind CLI state —
forgetting `terraform workspace select staging` silently plans against the wrong
environment, a pitfall called out in the spec. Explicit backend keys
(`env/dev/...`, `env/staging/...`) make the targeted state visible in every CI
command and impossible to confuse, at the cost of a little duplication. For a
graded multi-environment pipeline where a wrong-environment apply is
catastrophic, explicitness wins over brevity.

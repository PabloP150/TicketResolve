# TicketResolve — Terraform Workspace (`infra/`)

Workspace de Terraform que aprovisiona la infraestructura de TicketResolve en AWS.

- **Cloud provider:** AWS
- **Región por defecto:** `us-east-1`
- **Versión de Terraform:** `~> 1.8`
- **Versión del proveedor AWS:** `~> 5.0`
- **Estado:** **Remoto** (S3 + DynamoDB lock) desde Delivery 2 — ver [`bootstrap/`](bootstrap/) y [`backend.tf`](backend.tf).
- **Track:** Standard (no EKS) — CI sobre GitHub Actions

## Estructura del directorio

```
infra/
  versions.tf              # required_version + required_providers
  provider.tf              # provider "aws" + default_tags
  backend.tf               # S3 + DynamoDB remote state backend (D2)
  variables.tf             # input variables del root
  locals.tf                # naming derivado (no hardcoded en module calls)
  main.tf                  # llama a los módulos + monta API Gateway
  outputs.tf               # outputs consumibles por evidence scripts y D3+
  bootstrap/               # workspace separado para crear el state backend
    main.tf, variables.tf, outputs.tf, terraform.tfstate (committeado)
  modules/
    storage/               # bucket S3 reusable (versioning + lifecycle + SSE + SSL-only)
    database/              # tabla DynamoDB single-table con GSI1 y GSI2
    compute/               # Lambda + IAM execution role + log group
  envs/
    dev/dev.tfvars         # overrides para dev (lo usa el CI)
    prod/                  # vacío hasta Delivery 3+
  evidence/                # outputs CLI y screenshots requeridos por el rubric
  docs/                    # resúmenes por entrega (.md)
```

## Bootstrap workspace

Antes de poder usar este workspace con el backend remoto, el bucket de state y la tabla de lock tienen que existir. Eso se hace **una sola vez** en [`infra/bootstrap/`](bootstrap/README.md). Ver el README de ese subdirectorio para los detalles.

## Credenciales requeridas

El provider AWS se autentica usando las variables de entorno estándar de la CLI de AWS. **No** se hardcodean credenciales en ningún `.tf`.

| Variable                | Propósito                                        |
| ----------------------- | ------------------------------------------------ |
| `AWS_ACCESS_KEY_ID`     | Access Key del usuario IAM del equipo            |
| `AWS_SECRET_ACCESS_KEY` | Secret Key correspondiente                       |
| `AWS_REGION`            | Región (debe coincidir con `var.region`)         |

En CI se inyectan como GitHub Actions secrets con el mismo nombre. Las credenciales largas (long-lived) se reemplazarán por OIDC federation en Delivery 5.

## Inicialización y comandos

```bash
cd infra
terraform fmt -recursive
terraform init                                # usa el backend remoto definido en backend.tf
terraform validate
terraform plan -var-file=envs/dev/dev.tfvars
terraform apply -var-file=envs/dev/dev.tfvars
```

## Variables de entrada (root)

| Variable                  | Tipo   | Default     | Descripción                                                                 |
| ------------------------- | ------ | ----------- | --------------------------------------------------------------------------- |
| `environment`             | string | _(none)_    | `dev` o `prod`. Drives naming/tagging.                                      |
| `app_name`                | string | _(none)_    | Prefijo de nombres y tag `Project`.                                         |
| `region`                  | string | `us-east-1` | Región de AWS donde se crean los recursos.                                  |
| `architecture`            | string | `x86_64`    | CPU arch por defecto para futuros workloads (tag/env propagado).            |
| `lambda_memory_default`   | number | `256`       | MB de memoria por defecto para Lambdas livianas.                            |
| `lambda_timeout_default`  | number | `10`        | Timeout por defecto (s) para Lambdas livianas.                              |

Cada módulo define además sus propios inputs específicos — ver el README de cada módulo en `modules/<nombre>/`.

## Outputs (root)

| Output                    | Descripción                                                              |
| ------------------------- | ------------------------------------------------------------------------ |
| `workspace_region`        | Región AWS efectiva.                                                     |
| `attachments_bucket_name` | Bucket S3 para adjuntos de tickets.                                      |
| `attachments_bucket_arn`  | ARN del bucket de attachments (para IAM policies aguas abajo).           |
| `reports_bucket_name`     | Bucket S3 para reportes PDF mensuales.                                   |
| `reports_bucket_arn`      | ARN del bucket de reportes.                                              |
| `database_table_name`     | Nombre de la tabla DynamoDB single-table.                                |
| `database_table_arn`      | ARN de la tabla.                                                         |
| `database_stream_arn`     | ARN del DynamoDB Stream (lo consumirá un Lambda de auditoría en D4).     |
| `lambda_function_names`   | Map `logical_key -> function_name` para los 5 Lambdas.                   |
| `lambda_function_arns`    | Map `logical_key -> arn` para los 5 Lambdas.                             |
| `api_gateway_endpoint`    | Endpoint público HTTPS del API Gateway HTTP API.                         |
| `api_gateway_id`          | ID del HTTP API.                                                         |

## Módulos

### `modules/storage`

Provisiona **un** bucket S3 con: versioning enabled, lifecycle rules con prefijo obligatorio, SSE-S3 (AES256), bucket policy que niega `s3:*` cuando `aws:SecureTransport=false`, y bloqueo total de acceso público. Inputs: `bucket_name`, `environment`, `lifecycle_rules` (lista de objetos con `id`, `prefix`, opcional `transition_days/transition_storage_class`, opcional `expiration_days`). Outputs: `bucket_arn`, `bucket_name`, `bucket_regional_domain_name`.

Llamado dos veces desde el root: una para `attachments` (transición a IA a 30 días, expiración 1 año) y otra para `reports` (expiración a 90 días).

### `modules/database`

Provisiona **una** tabla DynamoDB single-table: `PK` (string) como hash key, `SK` (string) como sort key, **GSI1** (`GSI1PK`/`GSI1SK`, projection ALL) para el dashboard del ingeniero ordenado por SLA, **GSI2** (`GSI2PK`/`GSI2SK`, projection ALL) para detección de duplicados por hash de evento. TTL habilitado sobre el atributo `ttl`. SSE habilitado con default AWS-managed keys. Stream `NEW_AND_OLD_IMAGES` habilitado para el auditor de D4. Outputs: `table_arn`, `table_name`, `gsi1_arn`, `gsi2_arn`, `stream_arn`.

### `modules/compute`

Provisiona **un** Lambda + IAM execution role + CloudWatch log group + código Python placeholder via `data "archive_file"`. La execution role incluye solo permisos mínimos sobre el propio log group (sin wildcards) más los `additional_iam_statements` que el caller pase (cada uno con `sid`, `actions` y `resources` explícitos — wildcards rechazadas por `validation`). Outputs: `function_arn`, `function_name`, `invoke_arn`, `role_arn`, `role_name`, `log_group_name`.

Llamado cinco veces desde el root: `api-tickets`, `webhook-ingesta`, `escalamiento`, `notificacion`, `reporte-pdf`. Cada uno con su memoria/timeout y sus permisos scoped (acceso a la tabla DynamoDB y/o a los buckets que realmente usa).

### API Gateway HTTP API (a nivel root)

No es un módulo: vive directamente en `main.tf` porque su única razón de ser es atar los outputs de los Lambdas. Define un HTTP API con dos rutas: `POST /api/v1/incidents` → `lambda_api_tickets`, `POST /api/v1/webhooks` → `lambda_webhook_ingesta`. CORS abierto durante desarrollo.

## Pipeline de CI

El workflow [`.github/workflows/terraform-ci.yml`](../.github/workflows/terraform-ci.yml) se dispara en cada Pull Request hacia `main` y ejecuta:

1. `terraform fmt --check -recursive`
2. `terraform init -input=false -lock-timeout=60s` _(D2: init completo con backend remoto, ya no `-backend=false` porque el plan necesita leer el state)_
3. `terraform validate`
4. `terraform plan -var-file=envs/dev/dev.tfvars -lock-timeout=60s`
5. Publica el output del plan como comentario colapsable en el PR (non-blocking desde el fix post-D1).

Los pasos 1–4 bloquean el merge si fallan. El plan adquiere el lock de DynamoDB durante su corrida; corre rápido y lo libera al terminar.

## Evidence

Artefactos requeridos por el rubric, capturados durante la corrida real de aprovisionamiento de Delivery 2.

### Compute deployed — `aws lambda get-function` + `list-functions`

Archivo: [`evidence/compute-deployed.txt`](evidence/compute-deployed.txt)

```text
--------------------------------------------------------------------------------------------------
|                                           GetFunction                                          |
+--------------+---------------------------------------------------------------------------------+
|  FunctionArn |  arn:aws:lambda:us-east-1:010526283195:function:ticketresolve-api-tickets-dev   |
|  LastModified|  2026-05-21T05:23:35.220+0000                                                   |
|  MemorySize  |  512                                                                            |
|  Runtime     |  python3.12                                                                     |
|  State       |  Active                                                                         |
|  Timeout     |  10                                                                             |
+--------------+---------------------------------------------------------------------------------+

--- All 5 TicketResolve Lambdas (aws lambda list-functions filtered) ---

-----------------------------------------------------------------------------------
|                                  ListFunctions                                  |
+--------+-------------------------------------+-------------+--------+-----------+
| Memory |                Name                 |   Runtime   | State  |  Timeout  |
+--------+-------------------------------------+-------------+--------+-----------+
|  512   |  ticketresolve-api-tickets-dev      |  python3.12 |  None  |  10       |
|  1024  |  ticketresolve-reporte-pdf-dev      |  python3.12 |  None  |  60       |
|  256   |  ticketresolve-escalamiento-dev     |  python3.12 |  None  |  60       |
|  256   |  ticketresolve-notificacion-dev     |  python3.12 |  None  |  30       |
|  512   |  ticketresolve-webhook-ingesta-dev  |  python3.12 |  None  |  10       |
+--------+-------------------------------------+-------------+--------+-----------+
```

> El campo `State` aparece como `None` en `list-functions` porque ese subcommand devuelve solo `FunctionConfiguration` summary; el `State: Active` real de cada Lambda se confirma con `get-function` (primer cuadro). Los 5 Lambdas están `Active` en `us-east-1`.

### Remote state migration — `terraform init` output

Archivo: [`evidence/state-migration.txt`](evidence/state-migration.txt)

Confirmación clave: `Successfully configured the backend "s3"!` + `terraform state list` lee 69 entries desde S3 + `aws s3 ls s3://ticketresolve-tfstate-010526283195/infra/` muestra `terraform.tfstate` (150KB).

### Lock contention — DynamoDB rechaza un segundo plan concurrente

Archivo: [`evidence/state-lock-contention.png`](evidence/state-lock-contention.png)

![state lock contention error rendered from the failing plan run](evidence/state-lock-contention.png)

Reproducción: con un `terraform plan` corriendo en background sosteniendo el lock, un segundo `terraform plan -lock-timeout=4s` falla con `Error: Error acquiring the state lock` (`ConditionalCheckFailedException` desde la tabla `ticketresolve-tflock` en DynamoDB). El segundo proceso muestra el lock owner (host, PID, operación y timestamp) — exactamente el comportamiento que la tabla de lock está pensada para prevenir.

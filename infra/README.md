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
  main.tf                  # llama a los módulos (storage/database/compute/network/security/ingress) + seed
  moved.tf                 # state migration del API Gateway a modules/ingress (D3)
  outputs.tf               # outputs consumibles por evidence scripts y D3+
  bootstrap/               # workspace separado para crear el state backend
    main.tf, variables.tf, outputs.tf, terraform.tfstate (committeado)
  modules/
    storage/               # bucket S3 reusable (versioning + lifecycle + SSE + SSL-only)
    database/              # tabla DynamoDB single-table con GSI1 y GSI2
    compute/               # Lambda + IAM execution role + log group (source_dir opcional)
    network/               # VPC + subnets (pública/privada-app/privada-data ×2 AZ) + IGW + NAT + route tables + Gateway Endpoints (D3)
    security/              # SGs web/app/db (SG-to-SG) + NACLs pública/privada (D3)
    ingress/               # API Gateway HTTP API + Lambda proxy + health check (D3)
  lambda_src/
    api_tickets/           # handler Python real para el E2E proof (GET DynamoDB / POST S3) (D3)
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
| `ingress_url`             | URL del recurso `/api/v1/incidents` (endpoint E2E GET/POST).            |
| `health_check_url`        | URL del health/readiness check del ingress.                             |
| `vpc_id`                  | ID de la VPC (módulo network).                                          |
| `public_subnet_ids`       | IDs de subnets públicas (una por AZ).                                   |
| `private_subnet_ids`      | IDs de todas las subnets privadas (app + data).                         |
| `private_app_subnet_ids`  | IDs de subnets privadas-app (ENIs de Lambda).                          |
| `private_data_subnet_ids` | IDs de subnets privadas-data (reservadas).                             |
| `nat_gateway_ids`         | IDs de NAT Gateway(s).                                                  |
| `security_group_ids`      | Map `tier -> sg id` (web/app/db).                                       |

## Módulos

### `modules/storage`

Provisiona **un** bucket S3 con: versioning enabled, lifecycle rules con prefijo obligatorio, SSE-S3 (AES256), bucket policy que niega `s3:*` cuando `aws:SecureTransport=false`, y bloqueo total de acceso público. Inputs: `bucket_name`, `environment`, `lifecycle_rules` (lista de objetos con `id`, `prefix`, opcional `transition_days/transition_storage_class`, opcional `expiration_days`). Outputs: `bucket_arn`, `bucket_name`, `bucket_regional_domain_name`.

Llamado dos veces desde el root: una para `attachments` (transición a IA a 30 días, expiración 1 año) y otra para `reports` (expiración a 90 días).

### `modules/database`

Provisiona **una** tabla DynamoDB single-table: `PK` (string) como hash key, `SK` (string) como sort key, **GSI1** (`GSI1PK`/`GSI1SK`, projection ALL) para el dashboard del ingeniero ordenado por SLA, **GSI2** (`GSI2PK`/`GSI2SK`, projection ALL) para detección de duplicados por hash de evento. TTL habilitado sobre el atributo `ttl`. SSE habilitado con default AWS-managed keys. Stream `NEW_AND_OLD_IMAGES` habilitado para el auditor de D4. Outputs: `table_arn`, `table_name`, `gsi1_arn`, `gsi2_arn`, `stream_arn`.

### `modules/compute`

Provisiona **un** Lambda + IAM execution role + CloudWatch log group + código Python placeholder via `data "archive_file"`. La execution role incluye solo permisos mínimos sobre el propio log group (sin wildcards) más los `additional_iam_statements` que el caller pase (cada uno con `sid`, `actions` y `resources` explícitos — wildcards rechazadas por `validation`). Outputs: `function_arn`, `function_name`, `invoke_arn`, `role_arn`, `role_name`, `log_group_name`.

Llamado cinco veces desde el root: `api-tickets`, `webhook-ingesta`, `escalamiento`, `notificacion`, `reporte-pdf`. Cada uno con su memoria/timeout y sus permisos scoped (acceso a la tabla DynamoDB y/o a los buckets que realmente usa).

### `modules/network` (Delivery 3)

Provisiona la VPC completa: `aws_vpc` `10.20.0.0/16` (DNS support + hostnames), **6 subnets** en 2 AZs (2 públicas, 2 privadas-app, 2 privadas-data, cada una `/24`), un Internet Gateway, **1 NAT Gateway** (topología configurable con `single_nat_gateway`) con su Elastic IP en una subnet pública, route tables explícitas (1 pública → IGW, 1 privada-app por AZ → NAT, 1 privada-data solo-local) con sus asociaciones, y **2 Gateway VPC Endpoints** gratuitos (S3 y DynamoDB) asociados a las route tables privada-app. Inputs: `name_prefix`, `environment`, `vpc_cidr`, `availability_zones`, `public_subnet_cidrs`, `private_app_subnet_cidrs`, `private_data_subnet_cidrs`, `enable_nat_gateway`, `single_nat_gateway`, `tags`. Outputs: `vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_app_subnet_ids`, `private_data_subnet_ids`, `private_subnet_ids`, `nat_gateway_ids`, `internet_gateway_id`, route table ids y los ids de los Gateway Endpoints.

### `modules/security` (Delivery 3)

Define el control de acceso por capas. **SGs tier web→app→db** con reglas SG-to-SG (referencias de security group, no CIDRs) declaradas como recursos `aws_vpc_security_group_ingress_rule`/`egress_rule` **separados** para evitar el ciclo de dependencia. `web-sg`: ingress 80/443 desde `web_ingress_cidrs`, egress al app-sg. `app-sg`: ingress solo desde web-sg, egress al db-sg. `db-sg`: ingress solo desde app-sg en el puerto de BD, **sin ingress 0.0.0.0/0 y sin egress** (sin salida directa a Internet). **NACLs stateless**: una para subnets públicas y una para privadas, con reglas inbound/outbound explícitas (`aws_network_acl_rule`). Todos los puertos y CIDRs son variables. Consume `vpc_id`, `vpc_cidr` y subnet ids del módulo network. Outputs: `web_sg_id`, `app_sg_id`, `db_sg_id`, `public_nacl_id`, `private_nacl_id`.

### `modules/ingress` (Delivery 3)

Encapsula el **API Gateway HTTP API** (Lambda proxy) — el único punto de entrada público del compute. Rutas: `GET <health_check_path>` (health), `GET /api/v1/incidents` (E2E read), `POST /api/v1/incidents` (E2E write) → `api-tickets`; `POST /api/v1/webhooks` → `webhook-ingesta`. Incluye el stage `$default` con `auto_deploy` y los `aws_lambda_permission` que autorizan la invocación. Inputs: `api_name`, `environment`, `health_check_path`, config CORS, e invoke_arn/function_name de los dos Lambdas. Outputs: `api_id`, `api_endpoint`, `execution_arn`, `health_check_url`, `incidents_url`. En D2 estos recursos vivían inline en `main.tf`; D3 los migró aquí con bloques `moved{}` (ver [`moved.tf`](moved.tf)) — el `plan` mostró **0 destroy**.

## Pipeline de CI

El workflow [`.github/workflows/terraform-ci.yml`](../.github/workflows/terraform-ci.yml) se dispara en cada Pull Request hacia `main` y ejecuta:

1. `terraform fmt --check -recursive`
2. `terraform init -input=false -lock-timeout=60s` _(D2: init completo con backend remoto, ya no `-backend=false` porque el plan necesita leer el state)_
3. `terraform validate`
4. `terraform plan -var-file=envs/dev/dev.tfvars -lock-timeout=60s`
5. Publica el output del plan como comentario colapsable en el PR (non-blocking desde el fix post-D1).

Los pasos 1–4 bloquean el merge si fallan. El plan adquiere el lock de DynamoDB durante su corrida; corre rápido y lo libera al terminar.

**Apply on merge (Delivery 3).** El workflow [`.github/workflows/terraform-apply.yml`](../.github/workflows/terraform-apply.yml) se dispara en `push` a `main` (cambios bajo `infra/**`) y ejecuta `terraform init` + `terraform apply -auto-approve -var-file=envs/dev/dev.tfvars`, aprovisionando los recursos de red/seguridad/ingress además de compute/storage/database. Usa un `concurrency group` para que dos applies no compitan por el lock de state. Las credenciales se inyectan vía GitHub Actions secrets como `TF_VAR_*`/`AWS_*` — sin valores hardcodeados en el YAML; todo lo específico de ambiente vive en `envs/dev/dev.tfvars`.

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

---

## Evidence — Delivery 3 (Networking)

Track: **VPC-required**. Aprovisionado en la cuenta `010526283195` / `us-east-1`. VPC `vpc-0489f18f6463adda0`, NAT `nat-01602aa6280cc0a72`, API endpoint `https://o2mbl3sx1i.execute-api.us-east-1.amazonaws.com`.

### Deliverable A — Network Foundation (`terraform output`)

Archivo: [`evidence/network-foundation.txt`](evidence/network-foundation.txt)

```text
vpc_id                  = "vpc-0489f18f6463adda0"
public_subnet_ids       = ["subnet-0a7061f18be644d85", "subnet-07663e3e31b7f98b7"]
private_app_subnet_ids  = ["subnet-07f9c50261f15276b", "subnet-072c27b8cf25d1563"]
private_data_subnet_ids = ["subnet-0a63ade8e383b06b9", "subnet-01641b3ea39db5242"]
private_subnet_ids      = ["subnet-07f9c50261f15276b", "subnet-072c27b8cf25d1563",
                           "subnet-0a63ade8e383b06b9", "subnet-01641b3ea39db5242"]
nat_gateway_ids         = ["nat-01602aa6280cc0a72"]
security_group_ids      = { app = "sg-044a3e38e9e769099", db = "sg-01c1e5856bd509daf", web = "sg-0d5a8a6c43ce13a1a" }
```

### Deliverable B — Network Security

Plan excerpt de las reglas de SG/NACL: [`evidence/security-groups-plan.txt`](evidence/security-groups-plan.txt) — muestra `web-sg`/`app-sg`/`db-sg` con reglas SG-to-SG (`referenced_security_group_id`) y las NACLs pública/privada con sus reglas stateless explícitas.

Política IAM least-privilege del Lambda api-tickets (sin wildcards, scoped a la tabla + GSIs + bucket): [`evidence/api-tickets-iam-policy.txt`](evidence/api-tickets-iam-policy.txt).

Screenshot de consola (inbound/outbound rules): `evidence/security-groups.png` _(pendiente de captura en consola)_.

![security group rules](evidence/security-groups.png)

### Deliverable C — Public Ingress (`curl -v`)

Archivo: [`evidence/ingress-curl.txt`](evidence/ingress-curl.txt)

```text
> GET / HTTP/2
< HTTP/2 200
< content-type: application/json
{"status": "ok", "service": "api-tickets"}
```

Screenshot de la consola del API Gateway mostrando las integraciones/rutas: `evidence/ingress-healthy.png` _(pendiente de captura)_.

![api gateway integrations](evidence/ingress-healthy.png)

### Deliverable D — End-to-End Connectivity Proof

**GET** — lee de DynamoDB ([`evidence/e2e-get.txt`](evidence/e2e-get.txt)):

```text
> GET /api/v1/incidents HTTP/2
< HTTP/2 200
{"source": "dynamodb", "table": "ticketresolve-dev", "item": {"PK": "TICKET#seed", "SK": "META",
 "title": "Seed incident for the Delivery 3 end-to-end proof", "severity": "P2", "status": "OPEN",
 "source": "terraform-seed", "GSI1PK": "ASSIGN#unassigned", "GSI1SK": "STATUS#OPEN#SLA#2026-06-07T23:55:00Z"}}
```

**POST** — escribe a S3 ([`evidence/e2e-post.txt`](evidence/e2e-post.txt)):

```text
> POST /api/v1/incidents HTTP/2
< HTTP/2 201
{"source": "s3", "bucket": "ticketresolve-attachments-dev-010526283195",
 "key": "attachments/2026-06-07T18-12-07Z-e31dea2be3074b869f021d1e9363bfcb.json"}
```

El seed lo provisiona el recurso `aws_dynamodb_table_item.seed_ticket` (committeado, no insertado por consola). Screenshot del objeto en S3: `evidence/e2e-storage.png` _(pendiente de captura)_.

![object in S3](evidence/e2e-storage.png)

### Deliverable E — CI Pipeline

`plan-on-PR` ([`terraform-ci.yml`](../.github/workflows/terraform-ci.yml)) publica el plan como comentario del PR; `apply-on-merge` ([`terraform-apply.yml`](../.github/workflows/terraform-apply.yml)) aplica al hacer merge a `main`. Link del PR y screenshot del run exitoso: `evidence/ci-plan.png` _(pendiente de captura del run real del PR)_.

![ci plan run](evidence/ci-plan.png)

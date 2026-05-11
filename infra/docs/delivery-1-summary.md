# Delivery 1 — IaC Workspace Bootstrap & CI Pipeline

**Curso:** Optimizaciones y Performance — PDDS, Galileo
**Equipo:** Pablo Pineda, Christian Martínez (equipo de 2 — confirmado con instructores)
**Track:** Standard (no EKS) — CI sobre GitHub Actions
**Fecha:** 2026-05-10

---

## 1. Cloud provider y región

**Proveedor:** AWS
**Región:** `us-east-1`

### Rationale

<!-- JUSTIFICACIÓN 1 — Completar / revisar este párrafo:
     El PDF (sección 3.2 punto 1) pide explicar por qué se eligió AWS y por qué us-east-1.
     Sugerencias de argumentos a usar / adaptar:
       - AWS es el proveedor con mayor cobertura en los servicios del curso (los 7 componentes:
         EC2/Lambda/ECS, S3, RDS/DynamoDB, VPC, SQS/SNS/EventBridge, IAM/Secrets/KMS, CloudWatch).
       - us-east-1 ofrece el mayor catálogo de servicios y suele ser la primera región
         donde aparecen features nuevas (relevante para SQS FIFO, EventBridge Pipes, etc.).
       - Precios de cómputo y egress más bajos comparados con otras regiones.
       - Latencia razonable desde Guatemala (≈70ms) — aceptable para un proyecto académico
         que no requiere data residency en LATAM.
     -->

AWS fue seleccionado como proveedor porque cubre nativamente los siete componentes obligatorios del proyecto (compute, storage, database, networking, async processing, security, observability) bajo un único plano de control y un único modelo de IAM. La región `us-east-1` se eligió por su catálogo de servicios más amplio, precios más competitivos y por ser la primera región donde se liberan nuevas funcionalidades que serán útiles en deliveries siguientes (p. ej. EventBridge Pipes y SQS FIFO con deduplicación de alto throughput).

---

## 2. Recurso aprovisionado

Para Delivery 1 se aprovisiona **un único recurso real**: un bucket de Amazon S3 llamado `aws_s3_bucket.bootstrap`.

### ¿Por qué este recurso?

<!-- JUSTIFICACIÓN 2 — Completar / revisar este párrafo:
     El PDF (sección 3.2 punto 2) pide explicar por qué se eligió como primer recurso.
     Sugerencias:
       - S3 es el servicio AWS más simple de aprovisionar: no requiere VPC, ni subnet groups,
         ni configuración de red. Suficiente para validar credenciales y wiring de variables.
       - El bucket se reutilizará: en Delivery 2 será el target real (con versioning, encryption,
         lifecycle, etc.) del componente "Storage". En Delivery 5 puede albergar logs centralizados.
       - El plan output es corto y fácil de revisar — útil para la review del PR del Delivery 1.
     -->

Se eligió un bucket S3 porque (a) es uno de los servicios más simples de aprovisionar en AWS — no requiere VPC, subnet groups ni reglas de seguridad — lo cual lo hace ideal para validar de extremo a extremo el wiring de credenciales, variables y outputs sin introducir complejidad accidental; (b) es un recurso reutilizable: en Delivery 2 este bucket se promoverá al componente oficial de _Storage_ con `versioning`, `server_side_encryption_configuration` y `lifecycle_rule`, evitando trabajo desechable; (c) su `arn` es exactamente el tipo de valor que un módulo aguas abajo (p. ej. IAM policies en Delivery 5) consumirá, ejercitando la mecánica de outputs desde el primer día.

### Extracto de `terraform plan`

<!-- JUSTIFICACIÓN 3 — Pegar aquí el output real de `terraform plan` después de correrlo localmente.
     El bloque de abajo es un placeholder con la forma esperada del output. Reemplazarlo con
     el output real después de:
       1. cd infra && terraform init
       2. terraform plan -var-file=envs/dev/dev.tfvars
     Pegar la sección "Terraform will perform the following actions" hasta "Plan: 1 to add, 0 to change, 0 to destroy."
     -->

```hcl
Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # aws_s3_bucket.bootstrap will be created
  + resource "aws_s3_bucket" "bootstrap" {
      + arn                         = (known after apply)
      + bucket                      = "ticketresolve-bucket-dev"
      + bucket_domain_name          = (known after apply)
      + bucket_regional_domain_name = (known after apply)
      + force_destroy               = false
      + hosted_zone_id              = (known after apply)
      + id                          = (known after apply)
      + object_lock_enabled         = (known after apply)
      + region                      = "us-east-1"
      + request_payer               = (known after apply)
      + tags                        = {
          + "Application"  = "ticketresolve"
          + "Architecture" = "x86_64"
          + "Environment"  = "dev"
          + "Name"         = "ticketresolve-bucket-dev"
          + "Purpose"      = "delivery-1-bootstrap"
          + "Region"       = "us-east-1"
        }
      + tags_all                    = {
          + "Application"  = "ticketresolve"
          + "Architecture" = "x86_64"
          + "Delivery"     = "oyd-delivery-1"
          + "Environment"  = "dev"
          + "ManagedBy"    = "Terraform"
          + "Name"         = "ticketresolve-bucket-dev"
          + "Project"      = "ticketresolve"
          + "Purpose"      = "delivery-1-bootstrap"
          + "Region"       = "us-east-1"
        }
    }

Plan: 1 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + bootstrap_bucket_arn  = (known after apply)
  + bootstrap_bucket_name = (known after apply)
  + workspace_region      = "us-east-1"
```

---

## 3. Arquitectura del pipeline de CI

El pipeline vive en `.github/workflows/terraform-ci.yml` y se dispara en cada Pull Request hacia `main`. Ejecuta los siguientes pasos en orden, todos con `working-directory: infra/`:

| # | Step                           | Comando                                             | Bloquea PR si falla |
| - | ------------------------------ | --------------------------------------------------- | ------------------- |
| 1 | Checkout                       | `actions/checkout@v4`                               | Sí                  |
| 2 | Setup Terraform                | `hashicorp/setup-terraform@v3` (`~> 1.8`)           | Sí                  |
| 3 | Configure AWS credentials      | `aws-actions/configure-aws-credentials@v4`          | Sí                  |
| 4 | Terraform Format Check         | `terraform fmt --check -recursive`                  | Sí                  |
| 5 | Terraform Init                 | `terraform init -backend=false`                     | Sí                  |
| 6 | Terraform Validate             | `terraform validate`                                | Sí                  |
| 7 | Terraform Plan                 | `terraform plan -var-file=envs/dev/dev.tfvars`      | Sí                  |
| 8 | Post Plan as PR Comment        | `actions/github-script@v7`                          | **No** (non-blocking) |

El job declara `permissions: { contents: read, pull-requests: write }` — el segundo es el permiso mínimo necesario para que `actions/github-script` pueda publicar el comentario del plan. El output del plan se envuelve en un bloque `<details>` colapsable, y se trunca a 60 KB si excediera el límite de caracteres de la API de comentarios de GitHub.

### Estrategia de credenciales

Las credenciales AWS se inyectan exclusivamente vía **GitHub Actions encrypted secrets**:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`

Ningún `.tf`, ningún `.tfvars` y ningún `.yml` committeado al repo contiene credenciales. El step 3 las exporta como variables de entorno del runner antes del `terraform plan`. Estas credenciales largas se reemplazarán por **OIDC federation** en el Delivery 5, eliminando la necesidad de access keys persistentes.

---

## 4. Diseño de variables

Todas las variables están definidas en [`infra/variables.tf`](../variables.tf) con `description`, `type` y, donde aplica, `validation` y `default`. Los valores concretos para `dev` viven en [`infra/envs/dev/dev.tfvars`](../envs/dev/dev.tfvars). Cada variable está cableada al menos al recurso bootstrap (ya sea en el nombre o en los tags), satisfaciendo el criterio del rubric.

| Variable        | Tipo   | Default     | Wiring en `dev`                 | Diferencia esperada en `prod`                              |
| --------------- | ------ | ----------- | ------------------------------- | ---------------------------------------------------------- |
| `environment`   | string | _(none)_    | `"dev"`                         | `"prod"` — drives sufijos de nombre y tags por entorno     |
| `app_name`      | string | _(none)_    | `"ticketresolve"`               | Mismo — el nombre de la aplicación no cambia entre entornos |
| `region`        | string | `us-east-1` | `"us-east-1"`                   | Podría seguir `us-east-1` o moverse a `us-east-2` por DR    |
| `architecture`  | string | `x86_64`    | `"x86_64"`                      | `arm64` en prod para reducir costos en Lambda/Graviton (Delivery 2+) |
| `bucket_name`   | string | _(none)_    | `"ticketresolve-bucket"`        | Base name distinto para evitar colisión global de nombres S3 |

Las cinco variables superan el mínimo de cuatro exigido por el PDF y cubren todas las categorías semánticas requeridas: `environment`, `app_name` (project name), `region`, y `bucket_name` como variable específica al recurso. `architecture` se incluye preventivamente porque será consumida por los módulos de compute en Delivery 2 sin que haya que retocar la firma del workspace.

---

## 5. Decisiones y trade-offs

### Decisión 1 — Estado local en lugar de remoto

Se optó por **mantener `terraform.tfstate` localmente** en Delivery 1, sin configurar un backend S3 + DynamoDB para state locking.

<!-- JUSTIFICACIÓN 4 — Revisar el párrafo de abajo. Argumentos cubiertos:
       - El PDF (sección 3.1.1) lo permite explícitamente para Deliveries 1–3.
       - Hacer remote state en Delivery 1 requiere bootstrappear un bucket de state + tabla DynamoDB,
         lo cual genera un problema circular (¿quién crea el bucket de state? ¿con qué state?)
         que normalmente se resuelve con dos workspaces.
       - Diferirlo a Delivery 2 (donde es un requisito explícito de grading) permite enfocarse en
         validar el wiring de provider/variables/outputs y el pipeline de CI en esta entrega.
     -->

El PDF permite estado local para Deliveries 1–3 y exige migración a remoto recién en Delivery 2 como criterio calificado. Configurar el backend remoto desde el día uno introduciría un problema de _bootstrap circular_: el bucket S3 que aloja el state también es un recurso Terraform que necesita un state donde guardarse. Resolverlo correctamente exige dos workspaces (uno _bootstrap_ con state local que crea el bucket, y otro _principal_ que usa el bucket). Esa complejidad es valiosa pero excede el alcance del Delivery 1, cuya meta declarada es validar estructura y pipeline, no aún la robustez del state. Por eso aceptamos la deuda técnica de estado local en esta entrega y la pagamos en Delivery 2 con un sub-workspace dedicado de bootstrap.

### Decisión 2 — Pinning de versión `~> 5.0` para el provider de AWS

Se pinneó el provider AWS con `version = "~> 5.0"` en lugar de un pin exacto (`= 5.62.0`) o un rango más amplio (`>= 5.0`).

<!-- JUSTIFICACIÓN 5 — Revisar el párrafo de abajo. Argumentos cubiertos:
       - "~> 5.0" permite minor y patch updates dentro de la major 5, pero bloquea automáticamente
         un salto a la major 6 (que podría introducir breaking changes).
       - Combinado con `.terraform.lock.hcl` (committeado), garantiza builds reproducibles entre
         miembros del equipo y el runner de CI.
       - Pin exacto (=5.62.0) sería más estricto pero obliga a abrir PRs para cada patch de
         seguridad menor, generando ruido.
       - El PDF (Common Pitfalls) penaliza wildcards (= "*") y no requiere pin exacto.
     -->

El operador `~> 5.0` admite actualizaciones de minor y patch dentro de la major 5 pero bloquea automáticamente un salto a la major 6, que históricamente ha traído cambios incompatibles en el provider de AWS. En conjunto con el archivo `.terraform.lock.hcl` (que sí se committea), esto garantiza builds bit-a-bit reproducibles entre los runners de CI y las máquinas del equipo, sin obligar a abrir un PR por cada patch de seguridad. Un pin exacto (`= 5.x.y`) sería más estricto pero generaría fricción operacional sin un beneficio claro a esta escala; un rango amplio (`>= 5.0`) violaría el _pitfall_ documentado en el PDF sobre wildcards.

### Decisión 3 _(opcional, recomendada)_ — `default_tags` en el provider

Se configuró el bloque `default_tags` directamente en el `provider "aws"` con cinco tags base (`Project`, `Environment`, `ManagedBy`, `Delivery`, y los tags por recurso).

<!-- JUSTIFICACIÓN 6 — Opcional. El rubric pide "al menos 2 decisiones" — esta puede dejarse o quitarse.
     Argumento:
       - default_tags aplica los tags a todos los recursos creados por el provider sin tener que
         repetirlos en cada bloque `resource`. Esto reduce drift entre módulos en deliveries futuros
         y habilita cost allocation tags desde el primer recurso.
     -->

`default_tags` aplica un conjunto base de tags a todos los recursos del workspace sin requerir que cada bloque `resource` los repita. Esto previene drift entre módulos en deliveries futuros, habilita _cost allocation_ desde el primer recurso, y se manifiesta visiblemente en el `tags_all` del plan output — facilitando la revisión durante el grading.

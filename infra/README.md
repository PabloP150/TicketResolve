# TicketResolve — Terraform Workspace (`infra/`)

Workspace de Terraform que aprovisiona la infraestructura de TicketResolve en AWS.

- **Cloud provider:** AWS
- **Región por defecto:** `us-east-1`
- **Versión de Terraform:** `~> 1.8`
- **Versión del proveedor AWS:** `~> 5.0`
- **Estado:** local (se migrará a remoto en el Delivery 2)
- **Track:** Standard (no EKS) — CI sobre GitHub Actions

## Estructura del directorio

```
infra/
  versions.tf       # required_version + required_providers
  provider.tf       # provider "aws" + default_tags
  variables.tf      # input variables
  outputs.tf        # outputs consumibles aguas abajo
  main.tf           # recurso bootstrap (un solo S3 bucket)
  envs/
    dev/dev.tfvars  # overrides para dev (usado por el CI)
    prod/           # vacío en Delivery 1
  modules/          # vacío en Delivery 1
  docs/             # resúmenes por entrega (.md)
```

## Inicialización del workspace

```bash
cd infra
terraform fmt -recursive
terraform init
terraform validate
```

`terraform init` descarga el provider de AWS y crea `.terraform/`. No se configura backend remoto en esta entrega; el estado se mantiene local (`terraform.tfstate`).

## Credenciales requeridas

El provider AWS se autentica usando las variables de entorno estándar de la CLI de AWS. **No** se hardcodean credenciales en ningún `.tf`.

| Variable                | Propósito                                        |
| ----------------------- | ------------------------------------------------ |
| `AWS_ACCESS_KEY_ID`     | Access Key del usuario IAM del equipo            |
| `AWS_SECRET_ACCESS_KEY` | Secret Key correspondiente                       |
| `AWS_REGION`            | Región (debe coincidir con `var.region`)         |

### Setear credenciales localmente

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"
```

Alternativamente, usar un perfil de `~/.aws/credentials`:

```bash
export AWS_PROFILE="ticketresolve-dev"
```

### Credenciales en CI (GitHub Actions)

Los mismos tres valores se inyectan como **GitHub Actions secrets** en el repositorio:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`

Para registrarlas (una sola vez, con `gh` autenticado):

```bash
gh secret set AWS_ACCESS_KEY_ID
gh secret set AWS_SECRET_ACCESS_KEY
gh secret set AWS_REGION
```

Las credenciales largas (long-lived) son aceptables sólo en Deliveries 1–4. En Delivery 5 se sustituirán por federación **OIDC**.

## Ejecutar plan y apply localmente

```bash
cd infra

# Plan: revisa qué se va a crear sin tocar nada
terraform plan -var-file=envs/dev/dev.tfvars -out=tfplan

# Apply: crea efectivamente el bucket bootstrap en AWS
terraform apply tfplan

# Destroy (opcional, para volver a estado limpio)
terraform destroy -var-file=envs/dev/dev.tfvars
```

> **Importante sobre `bucket_name`:** el nombre completo del bucket es
> `${bucket_name}-${environment}` (con `dev.tfvars` actual queda
> `ticketresolve-bucket-dev`) y debe ser **globalmente único en S3**.
> Si el apply falla con `BucketAlreadyExists`, cambia `bucket_name` en
> `envs/dev/dev.tfvars` a un valor único.

## Variables de entrada

| Variable        | Tipo     | Default     | Descripción                                                                 |
| --------------- | -------- | ----------- | --------------------------------------------------------------------------- |
| `environment`   | string   | _(none)_    | `dev` o `prod`. Drives naming/tagging.                                      |
| `app_name`      | string   | _(none)_    | Prefijo de nombres y tag `Project`.                                         |
| `region`        | string   | `us-east-1` | Región de AWS donde se crean los recursos.                                  |
| `architecture`  | string   | `x86_64`    | CPU arch por defecto para futuros workloads de compute. Se expone como tag. |
| `bucket_name`   | string   | _(none)_    | Base name (globalmente único) para el bucket bootstrap.                     |

## Outputs

| Output                 | Descripción                                                        |
| ---------------------- | ------------------------------------------------------------------ |
| `bootstrap_bucket_arn` | ARN del bucket bootstrap (consumido por módulos futuros).          |
| `bootstrap_bucket_name`| Nombre resuelto del bucket bootstrap.                              |
| `workspace_region`     | Región AWS efectiva del workspace.                                 |

## Pipeline de CI

El workflow [`.github/workflows/terraform-ci.yml`](../.github/workflows/terraform-ci.yml) se dispara en cada Pull Request hacia `main` y ejecuta:

1. `terraform fmt --check -recursive`
2. `terraform init -backend=false`
3. `terraform validate`
4. `terraform plan -var-file=envs/dev/dev.tfvars`
5. Publica el output del plan como comentario colapsable en el PR.

Los pasos 1–4 bloquean el merge si fallan. El paso 5 es non-blocking.

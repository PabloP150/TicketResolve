# Delivery 1 — IaC Workspace Bootstrap & CI Pipeline

**Curso:** Optimizaciones y Performance — PDDS, Galileo

**Equipo:** Pablo Pineda, Christian Martínez 

**Track:** Standard (no EKS) — CI sobre GitHub Actions

**Fecha:** 2026-05-10

---

## 1. Cloud provider y región

**Proveedor:** AWS
**Región:** `us-east-1`

### Elección de AWS como Proveedor de Nube

Se seleccionó AWS como proveedor principal debido a la experiencia previa del equipo con su ecosistema. Esto permite priorizar la calidad de la implementación y la estabilidad del sistema sobre la curva de aprendizaje de una plataforma nueva.

**Ventajas técnicas:**
* **Madurez del ecosistema de mensajería:** A diferencia de otros proveedores, la combinación nativa de SQS, SNS y EventBridge ofrece una granularidad superior para manejar patrones de mensajería asíncrona, fundamentales para la arquitectura del proyecto.
* **Modelo de IAM simplificado:** El esquema de identidad de AWS a nivel de cuenta es mucho más eficiente para un equipo ágil, evitando la sobrecarga operativa de gestionar jerarquías complejas de organizaciones y proyectos que presentan otras nubes.
* **Ecosistema de Terraform:** El provider de AWS es de los más estables y extensos, lo que permite utilizar módulos comunitarios probados para infraestructura de red y seguridad, evitando tener que "reinventar la rueda" en cada componente.

---

### Selección de Región (us-east-1)

La infraestructura se desplegará en la región `us-east-1` ya que es la región más apta y con menos latencia para un proyecto orientado a un público en Guatemala.

**Ventajas técnicas:**
* **Latencia mínima:** Es la región con menor tiempo de respuesta desde Guatemala. Esto agiliza tanto el aprovisionamiento a través de Terraform como las pruebas de integración desde los entornos locales.
* **Disponibilidad de servicios y costos:** Al ser la región principal de AWS, garantiza acceso inmediato a cualquier servicio nuevo y ofrece las tarifas más bajas para instancias on-demand, optimizando el presupuesto del proyecto.

---

## 2. Almacenamiento de Adjuntos con Amazon S3

Para TicketResolve, es necesario contar con un sistema robusto para manejar documentos visuales como capturas, fotos y logs. Amazon S3 se seleccionó como un componente ideal para la persistencia de estos documentos.

**Ventajas técnicas:**
* **Alta disponibilidad y durabilidad:** S3 garantiza que los archivos adjuntos de los tickets no se pierdan sin importar el volumen de datos.
* **Optimización del Backend (Presigned URLs):** El soporte nativo para los presigned URLs permite que los clientes carguen archivos directamente al bucket. Esto reduce la carga del servidor de aplicaciones, ya que el backend no debe procesar el flujo de datos de archivos pesados, mejorando la escalabilidad del sistema.

---

### Extracto de `terraform plan`

Output literal capturado del PR comment generado por el workflow `Terraform CI`
(PR [#1](https://github.com/PabloP150/TicketResolve/pull/1), run 25649224379):

```hcl
Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # aws_s3_bucket.bootstrap will be created
  + resource "aws_s3_bucket" "bootstrap" {
      + acceleration_status         = (known after apply)
      + acl                         = (known after apply)
      + arn                         = (known after apply)
      + bucket                      = "ticketresolve-bucket-dev"
      + bucket_domain_name          = (known after apply)
      + bucket_prefix               = (known after apply)
      + bucket_regional_domain_name = (known after apply)
      + force_destroy               = false
      + hosted_zone_id              = (known after apply)
      + id                          = (known after apply)
      + object_lock_enabled         = (known after apply)
      + policy                      = (known after apply)
      + region                      = (known after apply)
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
      + website_domain              = (known after apply)
      + website_endpoint            = (known after apply)
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

### 1. Desacoplamiento del estado remoto con `-backend=false`

Para los jobs de CI, decidimos correr el `terraform init` con el flag `-backend=false`. Esto se hizo con el propósito de que la validación y formato funcionen por si solos, sin tener que ir a traer el estado real a la nube cada vez que se sube un cambio.

**Ventajas técnicas:**

- **Seguridad:** Al no necesitar el estado (S3/DB) en los PRs, se elimina el riesgo de exponer credenciales sensibles. Si por algún motivo el workflow se ve comprometido, el atacante no tiene cómo acceder al estado de la infraestructura.
- **Pipeline más estable:** Si S3 o la base de datos demuestran latencia o caen, el flujo de desarrollo no se quedaría estancado. El equipo puede seguir validando el código sin depender de que los servicios de AWS estén al 100% en ese momento.

### 2. Uso de Access Keys en lugar de OIDC

En lugar de implementar federación de identidad con OIDC, se optó por utilizar Access Keys almacenadas en GitHub Secrets para la autenticación del proveedor de AWS.

**Ventajas técnicas:**

- **Resolución de dependencias circulares (Bootstrapping):** Implementar OIDC genera un problema: se requiere que Terraform cree el Identity Provider y el IAM Role en AWS, pero Terraform no puede ejecutarse para crearlos si no encuentra una identidad previamente configurada. Las llaves permiten romper esta dependencia inicial.
- **Reducción de Sobrecarga Operativa:** Configurar OIDC requiere definir políticas de confianza específicas para el repositorio, la organización y los branches. En esta etapa, el uso de llaves reduce los puntos de falla en el pipeline, evitando errores de autenticación por configuraciones de confianza o mal definidas en el proveedor de identidad.

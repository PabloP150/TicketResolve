# Delivery 2 — Compute, Storage, Database & Remote State

**Curso:** Optimizaciones y Performance — PDDS, Galileo
**Equipo:** Pablo Pineda, Christian Martínez (equipo de 2 — confirmado con instructores)
**Track:** Standard (no EKS) — CI sobre GitHub Actions
**Fecha:** 2026-05-21
**Provider / región:** AWS, `us-east-1`

---

## 1. Compute target y rationale

**Servicio elegido:** **AWS Lambda** (cinco funciones invocadas vía un API Gateway HTTP API).

En el curso paralelo de *Infraestructura en la Nube* (Entrega 2, §9), el equipo formalizó la decisión de compute sobre cinco funciones serverless en lugar del bucket S3 placeholder de Delivery 1. La razón es que TicketResolve combina dos perfiles de carga muy distintos: ingestas masivas e impredecibles de webhooks (ráfagas de hasta 500 alertas en 30 segundos) y trabajos pesados asíncronos (generación de PDFs, escalamiento programado). Lambda escala sin provisión previa, cobra solo por invocación + tiempo de ejecución, y se mantiene dentro del free tier permanente (1 M invocaciones + 400 K GB-seconds/mes), todo lo cual encaja con esos dos perfiles sin tener que provisionar capacidad ociosa.

**Trade-off arquitectónico considerado y aceptado.** La alternativa natural era ECS Fargate. Fargate elimina el problema de _cold start_ (los contenedores quedan calientes), lo cual sería una ventaja real para el SLA de 2 segundos del endpoint `POST /api/v1/incidents` cuando llega el primer pico de la mañana. La desventaja es que cobra por hora de runtime aunque no haya tráfico, y exige operar un cluster, definir tasks, balanceador y autoscaling — capas que solo se justifican si el tráfico sostenido es alto. Para un proyecto académico con ráfagas cortas y costo cero como restricción, asumimos los _cold starts_ de 200–1000 ms en la primera invocación y dejamos documentada la opción de pagar concurrencia reservada (~USD 0.015/mes por 100 unidades) si la presentación final lo requiere.

---

## 2. Diseño de los módulos

Las tres categorías obligatorias del rubric viven en `infra/modules/{compute,storage,database}/`, cada una con `main.tf`, `variables.tf` y `outputs.tf`. El root las llama y cablea sus outputs entre sí.

### `modules/storage`

**Inputs:** `bucket_name` (string, validado contra las reglas de naming de S3), `environment`, `lifecycle_rules` (lista de objetos con `id`, `prefix` obligatorio, y opcionalmente `transition_days/transition_storage_class`, `expiration_days`, `noncurrent_expiration_days`), `tags` (map opcional).
**Outputs:** `bucket_arn`, `bucket_name`, `bucket_regional_domain_name`.
**Responsabilidades:** crea el bucket, le habilita versioning y SSE-S3 (AES256), bloquea acceso público (los cuatro `block_*`), aplica el lifecycle pasado como input — **siempre con `prefix` dentro de un bloque `filter` para que la regla sea scoped** — y attachea una bucket policy que niega `s3:*` cuando `aws:SecureTransport=false`.

El root llama al módulo dos veces: `attachments_bucket` (lifecycle `attachments/` → IA a 30 días, expiración 1 año) y `reports_bucket` (lifecycle `reports/` → expiración a 90 días). Cada call pasa un `lifecycle_rules` distinto sin tocar el código del módulo.

### `modules/database`

**Inputs:** `table_name`, `environment`, `billing_mode` (default `PAY_PER_REQUEST`), `ttl_attribute_name` (default `ttl`), `tags`.
**Outputs:** `table_arn`, `table_name`, `gsi1_arn`, `gsi2_arn`, `stream_arn`.
**Responsabilidades:** crea una tabla DynamoDB single-table con `PK`/`SK` (string), dos GSIs (`GSI1` para el dashboard del ingeniero, `GSI2` para detección de duplicados por hash de evento), TTL habilitado sobre el atributo configurado, SSE habilitada con AWS-managed keys, y stream `NEW_AND_OLD_IMAGES` para el auditor que llega en D4.

### `modules/compute`

**Inputs:** `function_name`, `environment`, `memory_size` (default 256), `timeout` (default 10), `runtime` (default `python3.12`), `handler`, `environment_variables` (map), `additional_iam_statements` (lista de objetos `{sid, actions, resources}`), `log_retention_in_days`, `tags`.
**Outputs:** `function_arn`, `function_name`, `invoke_arn` (distinto del ARN, lo necesita API Gateway), `role_arn`, `role_name`, `log_group_name`.
**Responsabilidades:** empaqueta código Python placeholder con `data "archive_file"`, crea el log group con retención explícita, crea la execution role con trust policy para `lambda.amazonaws.com`, y le adjunta una inline policy que combina `logs:CreateLogStream` + `logs:PutLogEvents` (Resource scoped al log group ARN — sin wildcards) más los `additional_iam_statements` que el caller pase. Las wildcards en actions/resources están bloqueadas por un `validation` en `variables.tf`.

El root llama al módulo cinco veces, una por Lambda, con memoria/timeout específicos y statements scoped a la tabla DynamoDB y/o a los buckets que cada Lambda realmente usa.

### Decisión de diseño explicada: `additional_iam_statements` como input del módulo compute

Una alternativa habría sido exponer `role_name` como output y attachear cada policy adicional desde el root usando `aws_iam_role_policy_attachment` o `aws_iam_policy_attachment`. Lo rechazamos porque (a) genera condiciones de carrera entre el módulo y los recursos del root cuando Terraform decide el orden de creación, (b) parte la inline policy en múltiples policies pequeñas, complicando la auditoría, y (c) hace que el caller tenga que importar IAM helpers que no necesita para nada más. Pasarlas como input mantiene el módulo autosuficiente y le permite al `validation` rechazar wildcards en una sola vista — algo que el rubric pide explícitamente.

---

## 3. Remote state migration

### Pasos seguidos

1. **Workspace bootstrap separado.** Creamos [`infra/bootstrap/`](../bootstrap/README.md) con su propio `main.tf` / `variables.tf` / `outputs.tf`. Provisiona el bucket de state (`ticketresolve-tfstate-010526283195`) y la tabla de lock (`ticketresolve-tflock`). Ambos recursos llevan `lifecycle { prevent_destroy = true }`. Este workspace **no** tiene `backend "s3"`: usa state local a propósito y el `terraform.tfstate` resultante se commitea.
2. **`terraform apply` en bootstrap.** Una sola corrida manual produjo los outputs `state_bucket_name`, `lock_table_name`, `region`.
3. **Backend block hardcodeado en el main workspace.** Creamos [`infra/backend.tf`](../backend.tf) con los valores literales de bootstrap. Terraform no acepta variables ni locals en backend blocks; los valores quedan inline.
4. **Apply local antes de migrar.** Corrimos el `terraform apply` del main workspace mientras todavía no había backend block — produjo un `terraform.tfstate` local con los 41 recursos creados.
5. **`terraform init -migrate-state -force-copy`.** Tras agregar el `backend.tf`, init detectó el nuevo backend, copió el state local al bucket S3 sin pedir confirmación interactiva, y dejó el state local vacío (0 bytes).
6. **Verificación.** `terraform state list` ahora lee 69 entries desde S3; `aws s3 ls s3://ticketresolve-tfstate-010526283195/infra/` confirma el archivo de 150 KB; el local `terraform.tfstate` fue removido y `.gitignore` lo excluye junto con `*.tfstate.*`.

### Excerpt del init de migración

Capturado en [`evidence/state-migration.txt`](../evidence/state-migration.txt):

```
Initializing the backend...

Successfully configured the backend "s3"! Terraform will automatically
use this backend unless the backend configuration changes.

Initializing modules...
Initializing provider plugins...
- Reusing previous version of hashicorp/archive from the dependency lock file
- Reusing previous version of hashicorp/aws from the dependency lock file
- Using previously-installed hashicorp/archive v2.8.0
- Using previously-installed hashicorp/aws v5.100.0

Terraform has been successfully initialized!
```

| Campo | Valor |
| ----- | ----- |
| Bucket de state | `ticketresolve-tfstate-010526283195` |
| Llave (object key) | `infra/terraform.tfstate` |
| Tabla de lock | `ticketresolve-tflock` |
| Región | `us-east-1` |

### Lock contention (evidencia gráfica)

Archivo [`evidence/state-lock-contention.png`](../evidence/state-lock-contention.png) — renderizado del output literal de un segundo `terraform plan` mientras el primero sostenía el lock. El segundo proceso falla con `Error: Error acquiring the state lock` apoyado en un `ConditionalCheckFailedException` que viene directamente del `PutItem` de DynamoDB hacia la tabla `ticketresolve-tflock`. La lockId, el host, el PID y el timestamp del proceso ganador quedan visibles, demostrando que el lock distribuido funciona end-to-end.

---

## 4. Manejo de credenciales del database module

Para Delivery 2 elegimos **DynamoDB** como base de datos. DynamoDB no usa credenciales propias — el acceso lo controla **IAM**, no usuario/password. Eso elimina por completo la categoría de "credenciales committeadas" para este módulo: no hay `master_password`, no hay `sensitive = true`, no hay Secrets Manager por configurar en este delivery.

Lo que sí cuidamos rigurosamente es el **acceso por IAM**:

- **Sin wildcards en actions ni resources.** El `validation` del input `additional_iam_statements` del módulo compute rechaza la string `"*"` antes de que llegue a `terraform plan`. Cada Lambda obtiene solo los verbos que usa: `dynamodb:GetItem`, `BatchGetItem`, `Query`, `Scan`, `ConditionCheckItem` (read), y `PutItem`, `UpdateItem`, `DeleteItem`, `BatchWriteItem` (write).
- **Resources scoped a la tabla y a los GSIs.** Las statements pasan `module.database.table_arn` y `module.database.gsi1_arn` / `gsi2_arn` como recursos. Cada Lambda puede operar contra esa tabla específica, no contra el comodín de la cuenta.
- **Per-función.** `lambda_reporte_pdf` solo tiene acciones de read; `lambda_notificacion` no tiene ninguna acción de DynamoDB porque su trabajo (publicar a SNS) llega en Delivery 4.
- **SSE en reposo habilitado** dentro del módulo (`server_side_encryption { enabled = true }`) — la tabla queda encriptada con la clave AWS-managed de DynamoDB.
- **No hay nada committeado que sea sensible.** Ni `dev.tfvars`, ni `backend.tf`, ni el `terraform.tfstate` de bootstrap contienen secretos. Las credenciales de quien corre Terraform vienen de `~/.aws/credentials` (local) o GitHub Secrets (CI), y son las del usuario IAM `Pablo-Pineda`.

Si en una entrega futura migráramos a RDS (porque algún patrón de acceso lo justifique), la disciplina ya está montada: el password vendría de un input `sensitive = true` o leído de Secrets Manager con `data "aws_secretsmanager_secret_version"`, nunca inline.

---

## 5. Dos decisiones arquitectónicas con trade-off

### Decisión 1 — `billing_mode = PAY_PER_REQUEST` para la tabla DynamoDB

Optamos por el modo on-demand (`PAY_PER_REQUEST`) en lugar de `PROVISIONED` con autoscaling.

**Ventajas técnicas y de costo:**
- **Cero capacidad ociosa pagada.** En provisioned, aún sin tráfico se pagan RCUs/WCUs reservados; en on-demand se paga por request consumido. Para el patrón de TicketResolve (ráfagas impredecibles de webhooks + horas largas de inactividad) este modo es estrictamente más barato.
- **Free tier más generoso.** DynamoDB cubre 25 GB de almacenamiento y un volumen de operaciones más alto en PAY_PER_REQUEST que en provisioned, eliminando el riesgo de gasto inesperado durante el desarrollo.
- **Sin tunear autoscaling.** Provisioned exige decidir target utilization, min/max capacity y métricas de CloudWatch; on-demand absorbe los picos sin intervención humana, eliminando una categoría entera de bugs operacionales.

**Costo aceptado:** el precio por request es ~5x el de provisioned bien dimensionado en estado estable. Si TicketResolve creciera a tráfico sostenido de >1000 req/s constantes, valdría la pena medir y considerar la migración. A escala académica/demo eso no sucede, así que el trade-off es netamente favorable.

### Decisión 2 — Lifecycle rule con `prefix` explícito (`attachments/`, `reports/`) en lugar de aplicar al bucket completo

El rubric prohíbe explícitamente lifecycle rules sin prefix/filter, pero la decisión va más allá del cumplimiento: cada bucket podría haber tenido la regla aplicada a `prefix = ""` y haber pasado funcionalmente. Decidimos forzar prefijos significativos por dos razones técnicas concretas.

**Ventajas técnicas:**
- **Aislamiento ante errores de upload.** Si un cliente sube por accidente a la raíz del bucket (por ejemplo, un usuario que confunde URLs presigned), esos objetos quedan fuera del alcance de la regla y no se transicionan/expiran en silencio. El prefijo actúa como cinturón de seguridad: solo los objetos correctamente categorizados se ven afectados por el cycle de vida.
- **Multiples políticas por bucket si el negocio lo necesita.** Al estar el lifecycle scoped por prefix, mañana podemos agregar una regla adicional (`thumbnails/` con expiración más agresiva, `archive/` con retención más larga) sin reemplazar la existente. El módulo ya acepta una **lista** de `lifecycle_rules`, así que esta extensibilidad está implícita.

**Costo aceptado:** la convención de prefijo se vuelve un contrato implícito entre la aplicación y la infraestructura. Si un developer junior sube objetos a la raíz porque no sabe del prefijo, los archivos no caen bajo lifecycle y crecen el costo de S3 indefinidamente. Mitigación natural: documentado en el README del módulo y reforzado por código de aplicación que siempre prepende el prefijo en el `s3:PutObject`. Aceptamos esa carga documental a cambio de las dos ventajas anteriores.

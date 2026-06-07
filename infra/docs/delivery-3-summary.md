# Delivery 3 — Networking, Security & End-to-End Connectivity

**Curso:** Optimizaciones y Performance — PDDS, Galileo
**Equipo:** Pablo Pineda, Christian Martínez (equipo de 2 — confirmado con instructores)
**Track:** VPC-required
**Fecha:** 2026-06-07
**Provider / región:** AWS, `us-east-1`

---

## 1. Networking track y rationale

**Track elegido:** **VPC-required** (no serverless-only).

La arquitectura de TicketResolve (cinco Lambdas + DynamoDB + API Gateway HTTP API) técnicamente *califica* para el track serverless-only — no hay nada en el stack que exija una VPC para funcionar. Aun así, optamos por VPC-required por tres razones concretas:

1. **Coherencia entre cursos.** El curso paralelo de *Infraestructura en la Nube* (Entrega 3 — Red, [§13](../../cloud/Entrega-3-Red.md)) ya diseñó una VPC completa segmentada en tres capas para TicketResolve. Construir esa misma VPC en Terraform mantiene un único diseño de red defendible en ambos cursos, en lugar de mantener dos historias de arquitectura paralelas e inconsistentes.
2. **El track serverless trae una dependencia externa innecesaria.** Esa ruta exige aprovisionar un dominio custom + certificado ACM + zona Route 53 con validación DNS *en vivo* — three piezas que dependen de un registrador externo y de tiempos de propagación fuera del control del equipo, y que no aportan nada al objetivo pedagógico de la entrega (demostrar segmentación de red, SGs, NACLs y conectividad E2E).
3. **La VPC es el landing zone de la futura capa de datos relacional.** El diseño ya reserva subnets `private-data` vacías para RDS/ElastiCache (ver [§9 y §10 de Entrega 2](../../cloud/entrega-2-diseno-aplicacion.md)). Provisionar la VPC ahora evita un re-trabajo de red cuando esa capa aterrice.

### Diseño de CIDR

| Capa | AZ `us-east-1a` | AZ `us-east-1b` | Propósito |
| --- | --- | --- | --- |
| VPC | `10.20.0.0/16` (RFC 1918, ~65 K IPs) | — | No colisiona con el `10.0.0.0/16` típico en un peering futuro |
| Pública | `10.20.0.0/24` | `10.20.1.0/24` | NAT Gateway hoy; ALB futuro |
| Privada-app | `10.20.10.0/24` | `10.20.11.0/24` | ENIs de Lambda cuando se adjunten a la VPC |
| Privada-data | `10.20.20.0/24` | `10.20.21.0/24` | Reservadas y vacías; RDS/ElastiCache futuro |

Tres capas × dos AZs × un `/24` por subnet: seis subnets en total, todas dentro del rango `/16` de la VPC, sin solapamiento entre capas ni entre AZs — cada futura migración de capa de datos puede crecer dentro de su `/24` sin reclamar espacio de otra capa.

### Topología NAT: single NAT gateway

Configuramos `single_nat_gateway = true`: un único NAT Gateway en la subnet pública de `us-east-1a` (`10.20.0.0/24`), y las dos route tables privada-app (una por AZ) apuntan a ese mismo NAT.

**Rationale costo vs disponibilidad.** Un NAT por AZ cuesta aproximadamente el doble (~USD 64/mes en dos NATs vs ~USD 32/mes en uno solo, sin contar el tráfico procesado). Elegimos single-NAT y aceptamos el riesgo de que, si cae `us-east-1a`, las Lambdas que eventualmente residan en `private-app-b` (`10.20.11.0/24`) pierdan egress a Internet de forma temporal — sin afectar su conectividad a DynamoDB o S3, que llega por Gateway Endpoint y no por el NAT. Para una carga académica este riesgo es aceptable; la alta disponibilidad del NAT (`single_nat_gateway = false`, un NAT por AZ) queda señalada para reevaluarse en Delivery 5 si el caso de uso lo justifica.

---

## 2. Diseño del módulo `network` y arquitectura

El módulo vive en [`infra/modules/network/`](../modules/network/) con la estructura estándar `main.tf` / `variables.tf` / `outputs.tf`.

### Inputs

| Variable | Tipo | Propósito |
| --- | --- | --- |
| `name_prefix` | string | Prefijo de nombre (`ticketresolve-dev`), derivado en el root de `app_name` + `environment` |
| `environment` | string | Tag de ambiente |
| `vpc_cidr` | string (validado con `cidrhost`) | CIDR de la VPC |
| `availability_zones` | list(string) (≥ 2, validado) | AZs a usar; determina cuántas subnets de cada capa se crean |
| `public_subnet_cidrs` | list(string) | CIDRs de subnets públicas, una por AZ |
| `private_app_subnet_cidrs` | list(string) | CIDRs de subnets privada-app, una por AZ |
| `private_data_subnet_cidrs` | list(string) | CIDRs de subnets privada-data, una por AZ |
| `enable_nat_gateway` | bool | Activa/desactiva NAT(s) y la ruta default de privada-app |
| `single_nat_gateway` | bool | `true` = un solo NAT compartido; `false` = un NAT por AZ |
| `tags` | map(string) | Tags adicionales fusionados en cada recurso |

### Outputs

| Output | Contenido |
| --- | --- |
| `vpc_id`, `vpc_cidr` | Identidad y CIDR de la VPC |
| `public_subnet_ids` | IDs de las subnets públicas (lista, una por AZ) |
| `private_app_subnet_ids` | IDs de las subnets privada-app |
| `private_data_subnet_ids` | IDs de las subnets privada-data |
| `private_subnet_ids` | Combinado app + data — satisface el output de "lista de subnets privadas" que pide el rubric |
| `nat_gateway_ids` | IDs de los NAT Gateway(s) provisionados |
| `internet_gateway_id` | ID del IGW |
| `public_route_table_id` | ID de la route table pública |
| `private_app_route_table_ids` | IDs de las route tables privada-app (una por AZ) |
| `s3_vpc_endpoint_id`, `dynamodb_vpc_endpoint_id` | IDs de los Gateway Endpoints |

### Recursos provisionados

- **1 `aws_vpc`** con `enable_dns_support` y `enable_dns_hostnames` activados (requisito para que los Gateway Endpoints y futuros recursos resuelvan nombres DNS privados).
- **6 `aws_subnet`** (3 capas × 2 AZs), cada una etiquetada con su `Tier` (`public` / `private-app` / `private-data`).
- **1 `aws_internet_gateway`**, adjunto a la VPC.
- **`aws_eip` + `aws_nat_gateway`**, en cantidad determinada por la topología (`local.nat_gateway_count = enable_nat_gateway ? (single_nat_gateway ? 1 : az_count) : 0`). Con la configuración actual, esto produce exactamente un EIP y un NAT Gateway, ubicado en la subnet pública de `us-east-1a`.
- **1 route table pública**, compartida por las dos subnets públicas, con una ruta `0.0.0.0/0 → IGW` y sus dos asociaciones.
- **Route tables privada-app por AZ** (dos), cada una con su propia ruta `0.0.0.0/0 → NAT` — escrita de forma que, si mañana se cambia a `single_nat_gateway = false`, cada subnet automáticamente pasa a usar el NAT de su propia AZ sin tocar el resto del módulo (`nat_gateway_id = single_nat_gateway ? this[0].id : this[count.index].id`).
- **1 route table privada-data**, compartida, con únicamente la ruta local implícita de la VPC (sin ruta a Internet ni a NAT) y sus dos asociaciones — consistente con su rol de capa reservada y aislada.
- **2 `aws_vpc_endpoint` tipo Gateway** (S3 y DynamoDB), ambos asociados a las route tables privada-app. Son gratuitos y mantienen el tráfico hacia esos dos servicios fuera del NAT y de Internet.

### Cómo se consume y composición con otros módulos

El root cablea **todos** los inputs del módulo desde variables (`var.vpc_cidr`, `var.availability_zones`, `var.public_subnet_cidrs`, etc., con sus defaults declarados en `variables.tf` y replicables vía [`envs/dev/dev.tfvars`](../envs/dev/dev.tfvars)) — no hay CIDRs ni AZs hardcodeados en la llamada al módulo dentro de [`main.tf`](../main.tf).

```hcl
module "network" {
  source = "./modules/network"

  name_prefix = local.name_prefix
  environment = var.environment

  vpc_cidr                  = var.vpc_cidr
  availability_zones        = var.availability_zones
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  enable_nat_gateway        = var.enable_nat_gateway
  single_nat_gateway        = var.single_nat_gateway
}
```

Sus outputs alimentan directamente otros módulos:

- **`security/`** consume `vpc_id`, `vpc_cidr`, `public_subnet_ids` y `private_subnet_ids` para crear los security groups y las NACLs (sección 4).
- **`ingress/`** no depende de `network` — consume los `invoke_arn` de los Lambdas (el API Gateway HTTP API es un recurso regional sin necesidad de residir en una subnet).
- Los **Gateway Endpoints** quedan provisionados y asociados a las route tables privada-app, listos para el día en que el módulo `compute` reciba subnets/SGs y las Lambdas se adjunten a `private-app` — momento en el que el tráfico hacia DynamoDB y S3 fluirá por el endpoint sin pasar por el NAT.

### Por qué DynamoDB no aparece "dentro" de la VPC

DynamoDB es un **servicio gestionado fuera de la VPC**: no tiene una IP dentro de un rango de subnet, no se conecta a una route table ni a un security group de instancia. Se alcanza por dos caminos posibles — Internet/NAT, o un **Gateway VPC Endpoint** que inyecta una ruta hacia el prefijo del servicio en la route table asociada. Por eso el diseño no incluye un "DB subnet group" para DynamoDB (a diferencia de un motor relacional como RDS, que sí exige colocarse en subnets concretas): la capa `private-data` queda reservada y vacía precisamente para el día en que aparezca ese motor relacional, mientras que el acceso a DynamoDB desde cargas dentro de la VPC pasa — o pasará — por `aws_vpc_endpoint.dynamodb`.

---

## 3. Actualización del wiring de Delivery 2

**Honestidad sobre lo que había que refactorizar.** A diferencia de equipos que eligieron RDS / Cloud SQL — y que en D2 dejaron un `db_subnet_group` o un placeholder de IP privada que ahora debían apuntar a subnets reales — este equipo usa **DynamoDB**, que no reside en una VPC. El acceso es por **IAM**, alcanzable opcionalmente por Gateway Endpoint, nunca por una IP dentro de un rango de subnet. En consecuencia, **no existía ningún placeholder de networking de D2 que refactorizar** para la base de datos: el módulo `database` de D2 no tenía ningún input de red que migrar.

**Lo que sí se refactorizó: la extracción del API Gateway a un módulo dedicado.** En Delivery 2 el HTTP API (`aws_apigatewayv2_api`, sus integraciones, rutas, stage y permisos de invocación Lambda) vivía **inline en el root**. En Delivery 3 lo extrajimos a [`infra/modules/ingress/`](../modules/ingress/) para separar responsabilidades — el root ya no debe conocer los detalles de cómo se construye una integración AWS_PROXY o un permiso de invocación, solo pasarle los `invoke_arn` y nombres de función de los Lambdas correspondientes.

Esa extracción es un cambio de *dirección de estado*, no de infraestructura: si se hace con un simple `module` nuevo, Terraform destruiría el API en vivo (perdiendo su URL `$default`) y lo recrearía. Para evitarlo usamos bloques `moved {}` en [`infra/moved.tf`](../moved.tf) que renombran las direcciones de estado existentes hacia sus nuevas direcciones dentro de `module.ingress`:

```hcl
moved {
  from = aws_apigatewayv2_api.main
  to   = module.ingress.aws_apigatewayv2_api.this
}
moved {
  from = aws_apigatewayv2_integration.api_tickets
  to   = module.ingress.aws_apigatewayv2_integration.api_tickets
}
# ... 6 bloques moved más, uno por cada recurso de ingress (integraciones,
# rutas, stage, permisos de invocación Lambda)
```

`terraform plan` tras agregar estos bloques mostró **0 destroy** — Terraform reconcilió las direcciones y reportó únicamente los recursos nuevos del módulo `network`/`security` y la actualización in-place de `lambda_api_tickets` (nuevo handler real). El API Gateway HTTP API conservó su `api_id`, su `execution_arn` y su URL de invocación durante toda la migración.

### Excerpt de `terraform output` — networking

```
vpc_id                  = "vpc-0489f18f6463adda0"
public_subnet_ids       = ["subnet-0a7061f18be644d85", "subnet-07663e3e31b7f98b7"]
private_app_subnet_ids  = ["subnet-07f9c50261f15276b", "subnet-072c27b8cf25d1563"]
private_data_subnet_ids = ["subnet-0a63ade8e383b06b9", "subnet-01641b3ea39db5242"]
nat_gateway_ids         = ["nat-01602aa6280cc0a72"]
```

---

## 4. Seguridad: security groups y NACLs

El módulo [`infra/modules/security/`](../modules/security/) implementa la estrategia **SG-to-SG** de tres capas (web → app → db) más dos NACLs stateless.

### Por qué referencias de SG en lugar de rangos CIDR

Las reglas que referencian un security group de origen (`referenced_security_group_id`) siguen a las instancias/recursos sin importar su IP — no hay que mantener ni actualizar rangos cuando un recurso se recicla o escala horizontalmente. Es la postura recomendada por AWS para tráfico inter-tier dentro de una misma VPC, y es exactamente lo que el rubric espera ver en lugar de reglas `cidr_ipv4 = "10.20.x.x/24"` codificadas a mano.

### Mapeo de security groups

| SG | Nombre / ID | Ingress | Egress |
| --- | --- | --- | --- |
| **web** | `ticketresolve-dev-web-sg` / `sg-0d5a8a6c43ce13a1a` | `80` y `443` desde `var.web_ingress_cidrs` (`0.0.0.0/0` por default) | hacia **app-sg**, puerto `app_port` (`443`) |
| **app** | `ticketresolve-dev-app-sg` / `sg-044a3e38e9e769099` | **solo** desde **web-sg**, puerto `app_port` (`443`) | hacia **db-sg**, puerto `db_port` (`5432`) |
| **db** | `ticketresolve-dev-db-sg` / `sg-01c1e5856bd509daf` | **solo** desde **app-sg**, puerto `db_port` (`5432`) | **ninguna regla de egress** |

El `db-sg` no tiene **ninguna** regla `0.0.0.0/0` en ningún puerto, ni una sola regla de egress: Terraform deja el grupo sin reglas de salida, así que la capa de datos no tiene salida directa a Internet bajo ninguna circunstancia — ni siquiera si un proceso comprometido en esa capa intentara exfiltrar datos por una conexión saliente.

### Reglas como recursos separados, no bloques inline

Cada regla de SG está declarada como un recurso independiente — `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule` — en lugar de bloques `ingress {}` / `egress {}` inline dentro del `aws_security_group`. Esto es deliberado: si `web-sg` referenciara a `app-sg` (y viceversa) dentro de bloques inline, Terraform necesitaría conocer el ID final de ambos grupos *antes* de crear cualquiera de los dos, formando un ciclo de dependencia irresoluble — exactamente el pitfall que el rubric advierte para la estrategia SG-to-SG. Al declarar las reglas como recursos aparte, cada una depende solo del SG al que pertenece y del SG al que referencia, nunca al revés, y el grafo de dependencias queda acíclico: `web` → `app` → `db`.

### NACLs — stateless, reglas explícitas

| NACL | Subnets asociadas | Inbound (rule_action = allow) | Outbound (rule_action = allow) |
| --- | --- | --- | --- |
| **pública** | las 2 subnets públicas (`public_subnet_ids`) | `80`, `443`, efímero `1024–65535`, todos desde `0.0.0.0/0` | `80`, `443`, efímero `1024–65535`, todos hacia `0.0.0.0/0` |
| **privada** | las 4 subnets privadas (`private_subnet_ids` = app + data) | todo el tráfico (`protocol = "-1"`) desde `var.vpc_cidr`; efímero `1024–65535` desde `0.0.0.0/0` (retorno de NAT) | todo el tráfico hacia `var.vpc_cidr`; `443` y efímero `1024–65535` hacia `0.0.0.0/0` |

Cada regla es un `aws_network_acl_rule` independiente con `rule_number` explícito y `egress` booleano — necesario porque las NACLs son **stateless**: una conexión saliente no garantiza automáticamente que el tráfico de retorno sea permitido, hay que declararlo a mano (de ahí las reglas de puerto efímero en ambos sentidos).

Todos los puertos (`http_port`, `https_port`, `app_port`, `db_port`, `ephemeral_port_from/to`) y CIDRs (`web_ingress_cidrs`, `vpc_cidr`) son variables con `description`, sin valores mágicos en el cuerpo del módulo.

---

## 5. Prueba de conectividad end-to-end

### Runtime y handler

**Python 3.12 con `boto3`**, en [`infra/lambda_src/api_tickets/lambda_function.py`](../lambda_src/api_tickets/lambda_function.py). El módulo `compute` ahora acepta un input opcional `source_dir`: cuando está presente, empaqueta ese directorio real con `data "archive_file"` en lugar del placeholder de Delivery 2 (`var.source_dir == null ? data.archive_file.placeholder[0] : data.archive_file.from_source[0]`). El root invoca a `lambda_api_tickets` con `source_dir = "${path.module}/lambda_src/api_tickets"`.

### Los dos endpoints probados

Ambos son alcanzables **únicamente** a través del API Gateway HTTP API de ingreso — no existe URL de invocación directa expuesta a clientes (`aws_lambda_permission` restringe el `principal` a `apigateway.amazonaws.com` con `source_arn` scoped al `execution_arn` del API).

| Método y ruta | Acción | Resultado probado |
| --- | --- | --- |
| `GET /api/v1/incidents` | `get_item` sobre DynamoDB con `PK = "TICKET#seed"`, `SK = "META"`; retorna el item como JSON | **HTTP 200**, devolviendo el item real sembrado por Terraform |
| `POST /api/v1/incidents` | Escribe el cuerpo JSON de la petición al bucket de attachments con key `attachments/<timestamp>-<uuid>.json` | **HTTP 201**, con el `key` del objeto en la respuesta; objeto verificado presente en S3 |

```bash
# Lectura — DynamoDB
curl -s https://<api-id>.execute-api.us-east-1.amazonaws.com/api/v1/incidents
# -> 200 {"source": "dynamodb", "table": "ticketresolve-dev",
#         "item": {"PK": "TICKET#seed", "SK": "META", "title": "Seed incident...", ...}}

# Escritura — S3
curl -s -X POST https://<api-id>.execute-api.us-east-1.amazonaws.com/api/v1/incidents \
  -H 'Content-Type: application/json' \
  -d '{"summary": "smoke test desde curl"}'
# -> 201 {"source": "s3", "bucket": "ticketresolve-attachments-dev-010526283195",
#         "key": "attachments/2026-06-07T18-32-05Z-3f9a...json"}
```

### Flujo de configuración no sensible

```
var.* / dev.tfvars
  → environment_variables del módulo compute (TABLE_NAME, ATTACHMENTS_BUCKET)
    → variables de entorno del Lambda (Terraform las inyecta en el recurso aws_lambda_function)
      → os.environ["TABLE_NAME"], os.environ["ATTACHMENTS_BUCKET"] en el handler
```

```python
TABLE_NAME = os.environ["TABLE_NAME"]
ATTACHMENTS_BUCKET = os.environ["ATTACHMENTS_BUCKET"]
```

Nada está hardcodeado en el handler: ni el nombre de tabla, ni el bucket, ni la región (`boto3` la toma de `AWS_REGION`, inyectada automáticamente por el runtime de Lambda).

### Sobre secretos sensibles: por qué no hay un `DB_PASSWORD`

**DynamoDB no usa usuario/contraseña — el acceso es por IAM.** Es la misma postura documentada en el [§4 del summary de D2](./delivery-2-summary.md#4-manejo-de-credenciales-del-database-module): no existe la categoría "credencial de base de datos" para este stack, por lo tanto no hay nada que enrutar por GitHub Actions Secrets → `TF_VAR_*` en ese frente. Documentarlo así — en lugar de simular un flujo de secretos que no aplica — es la postura honesta y defendible en examen oral.

Lo que **sí** viene de GitHub Actions Secrets hacia el runner de CI son las credenciales de AWS necesarias para correr Terraform: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`. Esas sí son credenciales reales (del usuario IAM `Pablo-Pineda`), y nunca están committeadas — viven exclusivamente en la configuración de secrets del repositorio.

### Rol de ejecución IAM

`ticketresolve-api-tickets-dev-exec` (generado por el módulo `compute` como `"${var.function_name}-exec"`, con `function_name = "ticketresolve-api-tickets-dev"`). Permisos **scoped exactos, sin wildcards**, declarados vía `additional_iam_statements` en el root:

| Servicio | Acciones | Recurso |
| --- | --- | --- |
| DynamoDB | `GetItem`, `BatchGetItem`, `Query`, `Scan`, `ConditionCheckItem`, `PutItem`, `UpdateItem`, `DeleteItem`, `BatchWriteItem` | `arn:aws:dynamodb:us-east-1:010526283195:table/ticketresolve-dev` + sus índices `GSI1` y `GSI2` (3 ARNs explícitos vía `module.database.table_arn`, `gsi1_arn`, `gsi2_arn`) |
| S3 | `GetObject`, `PutObject`, `DeleteObject` | `arn:aws:s3:::ticketresolve-attachments-dev-010526283195/*` |
| S3 | `ListBucket` | `arn:aws:s3:::ticketresolve-attachments-dev-010526283195` |
| CloudWatch Logs | `CreateLogStream`, `PutLogEvents` (heredado del módulo `compute`) | el log group propio de la función, no `*` |

### Seed de datos

El item que `GET /api/v1/incidents` retorna **no se insertó por consola**: es un recurso Terraform — `aws_dynamodb_table_item.seed_ticket`, declarado en [`main.tf`](../main.tf) y committeado al repo — con `PK = "TICKET#seed"`, `SK = "META"`, severidad `P2`, estado `OPEN`, y `lifecycle { ignore_changes = [item] }` para que `terraform apply` no entre en conflicto si el handler llega a mutar ese item en una iteración futura.

---

## 6. Dos decisiones arquitectónicas con trade-off

### Decisión 1 — single NAT Gateway vs NAT por AZ

Elegimos `single_nat_gateway = true`: un solo NAT Gateway compartido en lugar de uno por zona de disponibilidad.

**Ventaja aceptada:** la mitad del costo recurrente — aproximadamente USD 32/mes contra USD 64/mes con dos NATs (sin contar el cargo por GB procesado, que se duplicaría también). Para un proyecto académico sin tráfico sostenido, ese ahorro es significativo y no compromete la funcionalidad de la demo.

**Riesgo aceptado:** si la zona `us-east-1a` (donde vive el único NAT) sufre una interrupción, las cargas que residan en `private-app-b` (`10.20.11.0/24`) pierden su ruta de egress hacia Internet de forma temporal — sin afectar su acceso a DynamoDB o S3, que viaja por Gateway Endpoint y nunca toca el NAT. Es un riesgo de disponibilidad real pero acotado, aceptable para una carga académica donde no hay SLA de producción que proteger; el módulo ya expone el toggle `single_nat_gateway` para pasar a HA por AZ sin reescritura, y esa reevaluación queda señalada explícitamente para Delivery 5.

### Decisión 2 — provisionar una VPC completa para un stack 100% serverless, manteniendo las Lambdas fuera de ella

Esta es una decisión de dos vías deliberada: por un lado se construye la VPC, las seis subnets, las route tables y los dos Gateway Endpoints (gratuitos); por otro, **las cinco Lambdas permanecen en la red administrada por defecto del servicio Lambda**, sin `vpc_config`, mientras la única persistencia del sistema sea DynamoDB y S3.

**Por qué se justifica la VPC de todas formas:** satisface el requisito del track elegido (sección 1) y construye, con costo marginal cero en los Gateway Endpoints, el landing zone exacto que necesitará la futura capa relacional — subnets `private-data` reservadas, `app-sg` ya definido para aceptar tráfico desde `web-sg`, y route tables privada-app ya enrutando hacia el NAT y los endpoints.

**Por qué las Lambdas se quedan fuera de la VPC por ahora:** adjuntar una función Lambda a una VPC le añade una ENI por instancia de ejecución concurrente, lo cual incrementa el *cold start* y agrega un paso de aprovisionamiento de red en cada invocación fría — un costo de latencia real que no compra ningún beneficio mientras DynamoDB y S3 (los únicos servicios con los que hablan estas funciones) son alcanzables por API pública con autenticación IAM, sin necesidad de residir en una subnet privada.

**Camino de migración ya construido:** el día que aparezca la capa relacional (RDS/ElastiCache en `private-data`), las Lambdas que necesiten hablarle se adjuntan a `private-app` — el `app-sg` ya existe y ya tiene la regla de egress hacia `db-sg` en el puerto `5432`, el NAT ya está enrutado, y los Gateway Endpoints ya mantienen el tráfico hacia DynamoDB/S3 fuera de esa ruta. La migración futura es de `vpc_config` en el módulo `compute`, no de rediseño de red.

---

## Evidencia y pendientes

Toda la evidencia requerida está capturada en [`infra/evidence/`](../evidence/) y renderizada en [`infra/README.md`](../README.md#evidence):

- **Deliverable A:** [`network-foundation.txt`](../evidence/network-foundation.txt) (`terraform output`).
- **Deliverable B:** [`security-groups-plan.txt`](../evidence/security-groups-plan.txt) (excerpt del plan) + [`security-groups.png`](../evidence/security-groups.png) (consola, `db-sg` sin ingress 0.0.0.0/0 y sin egress) + [`api-tickets-iam-policy.txt`](../evidence/api-tickets-iam-policy.txt) (IAM least-privilege).
- **Deliverable C:** [`ingress-curl.txt`](../evidence/ingress-curl.txt) (`curl -v`) + [`ingress-healthy.png`](../evidence/ingress-healthy.png) (rutas/integraciones del API Gateway).
- **Deliverable D:** [`e2e-get.txt`](../evidence/e2e-get.txt) (GET → DynamoDB, HTTP 200) + [`e2e-post.txt`](../evidence/e2e-post.txt) (POST → S3, HTTP 201) + [`e2e-storage.png`](../evidence/e2e-storage.png) (objeto en el bucket).
- **Deliverable E:** `ci-plan.png` — pendiente de capturar del run real del PR `plan-on-PR`.

**Pendiente menor — reevaluación de HA del NAT:** queda señalada para Delivery 5 (sección 6, decisión 1); no hay todavía una decisión tomada sobre migrar a `single_nat_gateway = false`.

---

**Equipo:** Pablo Pineda, Christian Martínez
**Fecha:** 2026-06-07
**Repo:** github.com/PabloP150/TicketResolve
**Track:** VPC-required

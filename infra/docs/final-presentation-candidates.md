# Presentación Final — Áreas candidatas de cambio de comportamiento

**Proyecto:** TicketResolve · **Curso:** Optimizaciones y Performance (PDDS, Galileo)
**Equipo:** Pablo Pineda, Christian Martínez · **Track:** VPC-required (AWS, `us-east-1`)
**Entregable de la Sesión 10** (Sección 4.1). Committeado a `main` antes de la sesión.

Este archivo lista las áreas candidatas de **comportamiento de la aplicación** para el cambio en vivo
(Segmento D). Describe *únicamente áreas y mecánicas* — el código real **no** está pre-escrito y se
implementará a partir del requerimiento específico del instructor durante la sesión.

**Recordatorio del pipeline (cómo llega cualquier cambio a staging):** el código de la API vive en
[`Dev/src/api_tickets/`](../../Dev/src/api_tickets/). `scripts/package_lambdas.sh` lo empaqueta; un
cambio en `Dev/src/**` dispara `terraform-apply.yml`, que empaqueta la Lambda y la aplica
(promoción por plan-artifact). El cambio es observable a través del ingress de la Entrega 3
(`POST/GET /api/v1/...`). Los tres checks requeridos son `terraform fmt`, `terraform validate`,
`terraform plan`; staging se promueve por `workflow_dispatch` detrás del gate de revisor requerido.

---

## Candidato 1 — Campo derivado en la respuesta de detalle del ticket

- **Título:** Campo computado en `meta` para `GET /api/v1/incidents/{id}` (ej.: `comment_count` —
  cuántos comentarios tiene el ticket; o `sla_status` "ON_TRACK"/"BREACHED").
- **Comportamiento observable (actual):** el endpoint devuelve `{meta, events[], comments[], attachments[]}`;
  `meta` no incluye un conteo ni un estado derivado de un vistazo. El cambio agrega un campo calculado
  en el servidor a `meta`, derivado de datos que el handler ya tiene en mano. Ejemplo más simple:
  `comment_count = len(comments)` (la lista de comentarios ya está ensamblada). Alternativa:
  `sla_status` comparando `sla_deadline` contra la hora UTC actual.
- **Endpoint y handler afectados:** `GET /api/v1/incidents/{id}` → `get_ticket()` en
  [`Dev/src/api_tickets/service.py`](../../Dev/src/api_tickets/service.py) (el bloque que ensambla y
  devuelve `meta`). Para la variante SLA, las constantes viven en
  [`Dev/src/shared/models.py`](../../Dev/src/shared/models.py) (`SLA_MINUTES`, `compute_sla_deadline`).
- **Método de verificación:** `curl -s $BASE/api/v1/incidents/<id> | jq '.meta.comment_count'` devuelve
  el campo nuevo; contrastar contra el baseline (el mismo `curl` antes del cambio) que lo trae en `null`.
- **Alcance estimado:** 1–2 líneas (una clave agregada al `meta` devuelto). Puramente aditivo — no cambia
  campos existentes.

## Candidato 2 — Parámetro de consulta en el listado del dashboard

- **Título:** Parámetro `limit` / `severity` / `sort` en `GET /api/v1/incidents`.
- **Comportamiento observable (actual):** el dashboard ya acepta `?assignee=` y `?status=` y devuelve
  `{items: [...]}` ordenado ascendentemente por SLA. **No** existe forma de limitar la cantidad de
  resultados, filtrar por severidad ni invertir el orden. El cambio lee un parámetro nuevo y lo aplica —
  p.ej. `?limit=N` trunca `items` a N, `?severity=P1` filtra por severidad, o `?sort=desc` invierte el
  orden por SLA.
- **Endpoint y handler afectados:** `GET /api/v1/incidents` → parseo de query en
  [`Dev/src/api_tickets/lambda_function.py`](../../Dev/src/api_tickets/lambda_function.py) (ya llama a
  `get_query_params`) → `list_dashboard()` en
  [`Dev/src/api_tickets/service.py`](../../Dev/src/api_tickets/service.py).
- **Método de verificación:** `curl -s "$BASE/api/v1/incidents?limit=1" | jq '.items | length'` devuelve
  a lo sumo 1; comparar contra `curl -s "$BASE/api/v1/incidents" | jq '.items | length'` (sin límite)
  como baseline. Para `severity`/`sort`, comparar el orden/contenido devuelto.
- **Alcance estimado:** pocas líneas (leer + validar un parámetro, aplicar un slice/filtro/orden al
  conjunto de resultados).

## Candidato 3 — Validación de entrada que retorna HTTP 400 en un POST

- **Título:** Rechazar un campo faltante/malformado con un `400` descriptivo en un endpoint de escritura.
- **Comportamiento observable (actual):** los endpoints de escritura validan sus campos requeridos
  existentes y lanzan `ValidationError` → `400` (p.ej. `create_ticket` valida `title/service/description`).
  El cambio agrega **una nueva** regla de validación — por ejemplo, exigir una longitud mínima o un
  conjunto permitido en un campo, o volver requerido un campo hoy opcional — devolviendo `400` con un
  cuerpo descriptivo cuando se viola, y comportándose normal en caso contrario.
- **Endpoint y handler afectados:** un handler POST en
  [`Dev/src/api_tickets/service.py`](../../Dev/src/api_tickets/service.py) — `create_ticket()`
  (`POST /api/v1/incidents`) o `add_comment()` (`POST /api/v1/incidents/{id}/comments`). La ruta de error
  ya existe: `raise models.ValidationError("...")` se traduce a `400` en
  [`Dev/src/api_tickets/lambda_function.py`](../../Dev/src/api_tickets/lambda_function.py).
- **Método de verificación:**
  `curl -s -o /dev/null -w '%{http_code}' -X POST $BASE/api/v1/incidents -d '<payload inválido>'`
  devuelve `400`; un payload válido sigue devolviendo `201`. Mostrar ambos.
- **Alcance estimado:** pocas líneas (una guarda + mensaje). **Nota:** mantener la regla compatible con
  los payloads del smoke test del CD (`scripts/smoke_test.sh`) para que el `smoke-test-dev` posterior al
  merge siga verde.

---

**Por qué estas áreas:** cada una soporta un cambio *quirúrgico de un solo archivo* (pocas líneas),
ejercita lógica real de la aplicación y acceso a DynamoDB/S3 (sin valores hardcodeados, sin no-ops) y
es verificable a través del ingress de la Entrega 3 con un solo `curl`, con un contraste
claro de antes/después.

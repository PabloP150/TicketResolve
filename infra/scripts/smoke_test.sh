#!/usr/bin/env bash
#
# smoke_test.sh — exercise the real, deployed API end-to-end over HTTPS.
#
# Drives the full incident lifecycle against the live canonical API URL
# (TLS custom domain when enable_tls=true, else the execute-api endpoint):
#   health -> create -> get -> comment -> resolve -> webhook alert -> report.
#
# Auth is intentionally deferred (the API is open at this stage), so no
# credentials are sent. Fails (non-zero exit) on the first unexpected status.
#
# Reads canonical_api_url from the Terraform workspace (must be init-ed).
# Requires: curl, jq.
#
# Usage:  infra/scripts/smoke_test.sh   [BASE_URL]
#   BASE_URL overrides the Terraform output (handy for local runs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE="${1:-$(terraform -chdir="${INFRA_DIR}" output -raw canonical_api_url 2>/dev/null || true)}"
if [[ -z "${BASE}" || "${BASE}" == "null" ]]; then
  echo "ERROR: no base URL (pass one as arg or expose canonical_api_url)." >&2
  exit 1
fi
BASE="${BASE%/}"  # strip trailing slash
echo "Smoke testing ${BASE}"

pass=0
fail=0

# check <description> <expected_status> <actual_status>
check() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1 (HTTP $3)"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 — expected $2, got $3" >&2
    fail=$((fail + 1))
  fi
}

# req <METHOD> <path> [json-body]  -> prints body, sets LAST_STATUS
LAST_STATUS=""
req() {
  local method="$1" path="$2" body="${3:-}"
  local tmp; tmp="$(mktemp)"
  local args=(-sS -o "${tmp}" -w '%{http_code}' -X "${method}" "${BASE}${path}")
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" -d "${body}")
  fi
  LAST_STATUS="$(curl "${args[@]}")"
  cat "${tmp}"
  rm -f "${tmp}"
}

# 1) Health
req GET / >/dev/null;                                                   check "health check" 200 "${LAST_STATUS}"

# 2) Create a ticket
created="$(req POST /api/v1/incidents '{"title":"smoke","description":"smoke test","severity":"P2","service":"smoke"}')"
check "create ticket" 201 "${LAST_STATUS}"
TICKET_ID="$(echo "${created}" | jq -r '.ticket_id')"
echo "  ticket_id=${TICKET_ID}"

# 3) Get it back
req GET "/api/v1/incidents/${TICKET_ID}" >/dev/null;                    check "get ticket" 200 "${LAST_STATUS}"

# 4) Comment
req POST "/api/v1/incidents/${TICKET_ID}/comments" '{"author":"smoke","body":"hi"}' >/dev/null
check "add comment" 201 "${LAST_STATUS}"

# 5) Resolve (state machine + async notification event)
req PATCH "/api/v1/incidents/${TICKET_ID}" '{"status":"RESOLVED","actor":"smoke","version":1}' >/dev/null
check "resolve ticket" 200 "${LAST_STATUS}"

# 6) Webhook alert ingestion (auto-severity + dedup)
req POST /api/v1/webhooks/alerts '{"service":"payments","alert_type":"HTTP_503"}' >/dev/null
check "webhook alert ingest" 201 "${LAST_STATUS}"

# 7) Trigger async monthly report
req POST /api/v1/reports '{}' >/dev/null;                               check "trigger report" 202 "${LAST_STATUS}"

echo "-------------------------------------------"
echo "Smoke test: ${pass} passed, ${fail} failed."
[[ "${fail}" -eq 0 ]] || exit 1

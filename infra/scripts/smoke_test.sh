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

# check <description> <actual_status> <expected_status>...  (one or more accepted)
check() {
  local desc="$1" actual="$2"; shift 2
  local exp
  for exp in "$@"; do
    if [[ "${actual}" == "${exp}" ]]; then
      echo "  PASS: ${desc} (HTTP ${actual})"
      pass=$((pass + 1))
      return
    fi
  done
  echo "  FAIL: ${desc} — expected ${*}, got ${actual}" >&2
  fail=$((fail + 1))
}

# req <METHOD> <path> [json-body]  -> sets LAST_STATUS, writes body to $BODY_FILE.
# NOTE: callers must NOT wrap req in command substitution ($(...)) — that runs it
# in a subshell where the LAST_STATUS assignment is lost. Read the body from
# $BODY_FILE after the call instead.
LAST_STATUS=""
BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT
req() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -o "${BODY_FILE}" -w '%{http_code}' -X "${method}" "${BASE}${path}")
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" -d "${body}")
  fi
  LAST_STATUS="$(curl "${args[@]}")"
}

# Unique suffix so re-runs always exercise creation paths (the webhook ingest
# dedups on service+alert_type, returning 200 instead of 201 for a repeat).
RUN_ID="$(date +%s)"

# 1) Liveness — the real app has no GET / health route; the incidents dashboard
#    (GET /api/v1/incidents) is the canonical 200 liveness probe.
req GET /api/v1/incidents;                                              check "liveness (dashboard)" "${LAST_STATUS}" 200

# 2) Create a ticket
req POST /api/v1/incidents '{"title":"smoke","description":"smoke test","severity":"P2","service":"smoke"}'
check "create ticket" "${LAST_STATUS}" 201
TICKET_ID="$(jq -r '.ticket_id' "${BODY_FILE}")"
echo "  ticket_id=${TICKET_ID}"

# 3) Get it back
req GET "/api/v1/incidents/${TICKET_ID}";                               check "get ticket" "${LAST_STATUS}" 200

# 4) Comment
req POST "/api/v1/incidents/${TICKET_ID}/comments" '{"author":"smoke","body":"hi"}'
check "add comment" "${LAST_STATUS}" 201

# 5) Resolve (state machine + async notification event)
req PATCH "/api/v1/incidents/${TICKET_ID}" '{"status":"RESOLVED","actor":"smoke","version":1}'
check "resolve ticket" "${LAST_STATUS}" 200

# 6) Webhook alert ingestion (auto-severity + dedup). Unique alert_type per run
#    so a fresh ticket is created (201); a repeat of the same alert dedups (200).
req POST /api/v1/webhooks/alerts "{\"service\":\"payments\",\"alert_type\":\"HTTP_503_${RUN_ID}\"}"
check "webhook alert ingest" "${LAST_STATUS}" 201 200

# 7) Trigger async monthly report
req POST /api/v1/reports '{}';                                          check "trigger report" "${LAST_STATUS}" 202

echo "-------------------------------------------"
echo "Smoke test: ${pass} passed, ${fail} failed."
[[ "${fail}" -eq 0 ]] || exit 1

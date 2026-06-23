#!/usr/bin/env bash
# Delivery 5 — finish script. Run AFTER the instructor has delegated the
# subdomain (so ACM DNS validation can complete). It:
#   1. verifies the delegation is live,
#   2. applies the TLS layer (enable_tls=true) to dev,
#   3. captures the TLS curl evidence (https 200 + http 301),
#   4. regenerates the output / state / idempotency evidence with TLS on.
#
# The one-click proof (destroy -> push to main -> CD) and the git tag are guided
# at the end — those are deliberate, reviewed actions you run yourself.
#
# Usage:  cd infra && bash scripts/finish-delivery-5.sh
set -euo pipefail

cd "$(dirname "$0")/.."   # -> infra/
export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1

SUB="grupo7.oyd.solid.com.gt"
API="api.${SUB}"
APP="app.${SUB}"

echo "==> 1. Checking NS delegation for ${SUB} ..."
if ! dig +short NS "${SUB}" | grep -q awsdns; then
  echo "    ERROR: ${SUB} is not delegated yet (no awsdns NS returned)."
  echo "    Ask the instructor to delegate, then re-run this script."
  exit 1
fi
echo "    OK — delegated. NS:"; dig +short NS "${SUB}" | sed 's/^/      /'

echo "==> 2. terraform init + apply with TLS enabled (this validates the ACM cert; can take 5-15 min) ..."
terraform init -reconfigure -input=false -backend-config=envs/dev/backend-dev.hcl >/dev/null
terraform apply -auto-approve -input=false -var-file=envs/dev/dev.tfvars

echo "==> 3. Capturing TLS curl evidence -> evidence/tls-curl.txt ..."
{
  echo "# Delivery 5 — Deliverable D (TLS) — curl evidence"
  echo "# ============================================================================"
  for url in "${API}" "${APP}"; do
    echo ""
    echo "### https://${url}  (expect TLS handshake + HTTP 200) ###"
    curl -sv --max-time 20 "https://${url}/" 2>&1 | grep -Ei "subject:|issuer:|SSL connection|HTTP/|< HTTP" | sed 's/^/  /' || true
  done
  echo ""
  echo "### http://${APP}  (expect HTTP 301 -> https via CloudFront) ###"
  curl -sv --max-time 20 "http://${APP}/" 2>&1 | grep -Ei "< HTTP|location:" | sed 's/^/  /' || true
} > evidence/tls-curl.txt
cat evidence/tls-curl.txt

echo "==> 4. Regenerating output / state / idempotency evidence (TLS on) ..."
terraform output > evidence/terraform-output-full.txt
terraform state list > evidence/state-list.txt
terraform plan -input=false -detailed-exitcode -var-file=envs/dev/dev.tfvars -no-color > evidence/idempotent-plan.txt 2>&1 \
  && echo "    idempotent-plan exit code: 0 (no changes)" \
  || echo "    idempotent-plan exit code: $? (2 = changes detected, investigate)"

cat <<'NEXT'

==> DONE with the TLS apply + evidence. Remaining MANUAL steps:

  A) Capture the remaining .png screenshots (console) into infra/evidence/:
     dashboard.png, budget.png, secrets-console.png, deployed-components.png,
     oidc-secrets-removed.png, oidc-auth-log.png, bot-command.png, bot-pipeline-run.png

  B) One-click proof (Deliverable F) — run the graded clean-state cycle:
       cd infra
       terraform destroy -var-file=envs/dev/dev.tfvars       # clean state (keep bootstrap!)
       # then merge PR #10 to main (or push to main) to trigger Terraform CD:
       gh pr merge 10 --merge
       # watch the run go green, screenshot it as evidence/clean-state-pipeline.png
       gh run watch

  C) Commit the new evidence and tag the delivery:
       git add infra/evidence
       git commit -m "Delivery 5: TLS + one-click evidence"
       git tag -a oyd-delivery-5 -m "Delivery 5: security, observability, one-click"
       git push origin main --tags
NEXT

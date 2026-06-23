#!/usr/bin/env bash
#
# deploy_frontend.sh — build the React SPA with the live API URL baked in and
# publish it to the CloudFront-fronted S3 bucket.
#
# This is the non-Terraform half of frontend hosting: Terraform creates the
# bucket + CloudFront (module.tls), and this script builds and uploads the
# static assets, then invalidates the CDN so the new build is served at once.
#
# Reads three Terraform outputs from the infra workspace (must already be
# `terraform init`-ed against the target environment's backend):
#   canonical_api_url               -> VITE_API_BASE (HTTPS; TLS custom domain)
#   spa_bucket_name                 -> aws s3 sync target
#   spa_cloudfront_distribution_id  -> cache invalidation target
#
# Usage:  infra/scripts/deploy_frontend.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
FRONTEND_DIR="${REPO_DIR}/Dev/frontend"

tf_output() { terraform -chdir="${INFRA_DIR}" output -raw "$1" 2>/dev/null || true; }

API_URL="$(tf_output canonical_api_url)"
BUCKET="$(tf_output spa_bucket_name)"
DIST_ID="$(tf_output spa_cloudfront_distribution_id)"

if [[ -z "${BUCKET}" || "${BUCKET}" == "null" ]]; then
  echo "SPA bucket output is empty/null — frontend hosting requires enable_tls=true."
  echo "Nothing to deploy; skipping."
  exit 0
fi
if [[ -z "${API_URL}" || "${API_URL}" == "null" ]]; then
  echo "ERROR: spa_bucket_name is set but canonical_api_url is empty — inconsistent state." >&2
  exit 1
fi

echo "Building SPA with VITE_API_BASE=${API_URL}"
cd "${FRONTEND_DIR}"
npm ci
VITE_API_BASE="${API_URL}" npm run build

echo "Uploading dist/ to s3://${BUCKET}/"
aws s3 sync dist/ "s3://${BUCKET}/" --delete

if [[ -n "${DIST_ID}" && "${DIST_ID}" != "null" ]]; then
  echo "Invalidating CloudFront distribution ${DIST_ID}"
  aws cloudfront create-invalidation --distribution-id "${DIST_ID}" --paths '/*' >/dev/null
fi

echo "Frontend deployed: ${API_URL%/*} SPA is live at the app.<subdomain> URL."

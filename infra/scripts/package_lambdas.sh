#!/usr/bin/env bash
#
# package_lambdas.sh — assemble deployable Lambda source trees from the real
# application code in Dev/src.
#
# Each function package is built under infra/build/lambda/<fn>/ containing:
#   - shared/          the common domain layer (every function imports it)
#   - <fn>/            the function's own package (service + lambda_function)
#   - (reporte_pdf)    its third-party deps vendored as LINUX wheels
#
# The Terraform `compute` module zips these directories via archive_file, and
# the Lambda handler is configured as "<fn>.lambda_function.lambda_handler".
#
# Cross-platform note: reporte_pdf depends on fpdf2 -> Pillow/fontTools, which
# ship binary wheels. The Lambda runtime is python3.12 on x86_64, so we vendor
# manylinux wheels explicitly (NOT the host's macOS/arm64 wheels) with
# --platform/--only-binary. pip only DOWNLOADS the prebuilt Linux .whl files
# (it never compiles or runs them locally), so the build is reproducible on a
# macOS dev machine and on the Linux CI runner alike.
#
# Usage:  infra/scripts/package_lambdas.sh
# Idempotent: the build dir is wiped and regenerated on every run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
SRC_DIR="${REPO_DIR}/Dev/src"
BUILD_DIR="${INFRA_DIR}/build/lambda"

# Must match the Terraform compute module runtime/architecture.
PY_VERSION="${LAMBDA_PY_VERSION:-3.12}"
PLATFORM="${LAMBDA_PLATFORM:-manylinux2014_x86_64}"
PIP="${PIP:-pip3}"

# Functions whose real handler lives in Dev/src. webhook_ingesta intentionally
# stays a provisioning placeholder: alert ingestion is served by api_tickets via
# POST /api/v1/webhooks/alerts (ingest_alert), so there is no separate handler.
FUNCTIONS=(api_tickets escalamiento notificacion reporte_pdf)

echo "Assembling Lambda packages from ${SRC_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

strip_caches() {
  find "$1" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "$1" -type f -name '*.pyc' -delete 2>/dev/null || true
}

for fn in "${FUNCTIONS[@]}"; do
  dest="${BUILD_DIR}/${fn}"
  mkdir -p "${dest}"
  cp -R "${SRC_DIR}/shared" "${dest}/shared"
  cp -R "${SRC_DIR}/${fn}" "${dest}/${fn}"
  strip_caches "${dest}"
  echo "  - ${fn}: shared/ + ${fn}/"
done

# reporte_pdf: vendor PDF dependencies as Linux wheels at the package root.
echo "Vendoring fpdf2 (Linux ${PLATFORM}, py${PY_VERSION}) into reporte_pdf/"
"${PIP}" install \
  --quiet --no-compile \
  --platform "${PLATFORM}" \
  --python-version "${PY_VERSION}" \
  --implementation cp \
  --only-binary=:all: \
  --target "${BUILD_DIR}/reporte_pdf" \
  "fpdf2>=2.7"
strip_caches "${BUILD_DIR}/reporte_pdf"

echo "Done. Packages under ${BUILD_DIR}"

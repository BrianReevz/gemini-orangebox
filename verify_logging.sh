#!/usr/bin/env bash
# ==============================================================================
# Read-only Verification Script for Gemini OrangeBox Multi-Project Logging
# ==============================================================================

set -euo pipefail

read_var() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="${3:-}"
  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi
  if [[ -n "${default_val}" ]]; then
    read -r -p "${prompt_text} [${default_val}]: " val
    printf -v "${var_name}" '%s' "${val:-${default_val}}"
  else
    read -r -p "${prompt_text}: " val
    printf -v "${var_name}" '%s' "${val}"
  fi
}

read_var MODEL_QUOTA_PROJECT_ID "Model & Quota Project ID"
read_var AUDIT_LOGGING_PROJECT_ID "Audit Logging Project ID"
read_var BQ_DATASET_ID "BigQuery Dataset ID" "genai_global_logs"
TABLE_ID="${TABLE_ID:-request_response_logging}"

touch "${HOME}/.bigqueryrc"

echo ""
echo "1) Checking BigQuery dataset location..."
LOC=$(bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" show --format=json "${AUDIT_LOGGING_PROJECT_ID}:${BQ_DATASET_ID}" | python3 -c "import sys,json; print(json.load(sys.stdin)['location'])")
echo "   Dataset ${AUDIT_LOGGING_PROJECT_ID}:${BQ_DATASET_ID} location = ${LOC}"
if [[ "${LOC}" != "US" ]]; then
  echo "   WARNING: Expected 'US' multi-region for global endpoint logging!"
fi

echo ""
echo "2) Checking BigQuery table ${TABLE_ID}..."
if bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" show "${AUDIT_LOGGING_PROJECT_ID}:${BQ_DATASET_ID}.${TABLE_ID}" >/dev/null 2>&1; then
  echo "   Table exists! Querying latest 5 rows..."
  bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" query --use_legacy_sql=false \
    "SELECT logging_time, model FROM \`${AUDIT_LOGGING_PROJECT_ID}.${BQ_DATASET_ID}.${TABLE_ID}\` ORDER BY logging_time DESC LIMIT 5"
else
  echo "   Table '${TABLE_ID}' does not exist yet."
  echo "   This is expected until the first inference call triggers async table creation (allow 2-5 min)."
fi

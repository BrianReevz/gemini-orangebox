#!/usr/bin/env bash
# ==============================================================================
# Gemini OrangeBox — Multi-Project Vertex AI & BigQuery Audit Logging Setup
# ==============================================================================
# Project-agnostic, Cloud Shell-ready setup script.
#
# What this script does (and nothing else):
#   1. Enables aiplatform.googleapis.com & provisions the Vertex AI P4SA in
#      your Model & Quota Project.
#   2. Enables bigquery.googleapis.com & creates a BigQuery dataset pinned to
#      the US multi-region in your Audit Logging Project.
#   3. Grants the Model & Quota Project's P4SA roles/bigquery.user (project)
#      and roles/bigquery.dataEditor (dataset-scoped) in the Audit Logging Project.
#   4. Enables 100% request/response + OTel logging on the global endpoint for
#      the configured Vertex AI models via setPublisherModelConfig.
#   5. (Optional) Grants a Client Workload caller principal roles/aiplatform.user
#      and roles/serviceusage.serviceUsageConsumer on the Model & Quota Project.
#
# Usage:
#   ./cloudshell_setup.sh              # Interactive prompts
#   ./cloudshell_setup.sh --dry-run    # Preview commands without making changes
# ==============================================================================

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "[DRY-RUN MODE] No changes will be made to your Google Cloud projects."
  echo ""
fi

DEFAULT_MODELS_CSV="gemini-4-argon-cyber-permissive,gemini-4-carbon-cyber-permissive,gemini-3.8-flash-cyber"
DATASET_LOCATION="US" # Mandatory: Vertex AI global endpoint requires US multi-region
TABLE_ID="${TABLE_ID:-request_response_logging}"

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="${3:-}"
  local current_val="${!var_name:-}"

  if [[ -n "${current_val}" ]]; then
    return 0
  fi

  while true; do
    if [[ -n "${default_val}" ]]; then
      read -r -p "${prompt_text} [${default_val}]: " input
      input="${input:-${default_val}}"
    else
      read -r -p "${prompt_text}: " input
    fi

    if [[ -n "${input}" ]]; then
      printf -v "${var_name}" '%s' "${input}"
      break
    fi
    echo "  Value cannot be empty. Please try again."
  done
}

prompt_optional() {
  local var_name="$1"
  local prompt_text="$2"
  local current_val="${!var_name:-}"

  if [[ -n "${current_val}" ]]; then
    return 0
  fi

  read -r -p "${prompt_text} (press Enter to skip): " input
  printf -v "${var_name}" '%s' "${input}"
}

echo "======================================================================"
echo "  Gemini OrangeBox — Multi-Project Vertex AI & BigQuery Audit Setup"
echo "======================================================================"
echo ""

prompt_required MODEL_QUOTA_PROJECT_ID "1) Model & Quota Project ID (hosts allowlisted models & P4SA)"
prompt_required AUDIT_LOGGING_PROJECT_ID "2) Audit Logging Project ID (hosts central BigQuery dataset)"
prompt_required BQ_DATASET_ID "3) BigQuery Dataset ID (created in US multi-region)" "genai_global_logs"
prompt_optional CLIENT_WORKLOAD_PROJECT_ID "4) Client Workload Project ID (for reference, optional)"
prompt_optional CLIENT_CALLER_PRINCIPAL "5) Client Caller Principal to grant inference access (e.g. serviceAccount:app@proj.iam.gserviceaccount.com)"
prompt_required MODELS_CSV "6) Comma-separated global model IDs" "${DEFAULT_MODELS_CSV}"

IFS=',' read -r -a MODELS <<< "${MODELS_CSV}"

echo ""
echo "Validating project access..."
for proj in "${MODEL_QUOTA_PROJECT_ID}" "${AUDIT_LOGGING_PROJECT_ID}"; do
  if ! gcloud projects describe "${proj}" --format="value(projectId)" >/dev/null 2>&1; then
    echo "ERROR: Cannot access project '${proj}'. Check the project ID and your permissions." >&2
    exit 1
  fi
done

BQ_OUTPUT_URI="bq://${AUDIT_LOGGING_PROJECT_ID}.${BQ_DATASET_ID}.${TABLE_ID}"

echo ""
echo "------------------------- Review Configuration -------------------------"
echo "Model & Quota Project   : ${MODEL_QUOTA_PROJECT_ID}"
echo "Audit Logging Project   : ${AUDIT_LOGGING_PROJECT_ID}"
echo "BigQuery Destination    : ${BQ_OUTPUT_URI} (location=${DATASET_LOCATION})"
if [[ -n "${CLIENT_WORKLOAD_PROJECT_ID:-}" ]]; then
  echo "Client Workload Project : ${CLIENT_WORKLOAD_PROJECT_ID}"
fi
echo "Client Caller Principal : ${CLIENT_CALLER_PRINCIPAL:-"(skipped)"}"
echo "In-Scope Models (global): ${MODELS[*]}"
echo "------------------------------------------------------------------------"
echo ""

if [[ "${AUTO_APPROVE:-false}" != "true" && "${DRY_RUN}" != "true" ]]; then
  read -r -p "Proceed with this configuration? [y/N]: " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "Aborted. No changes were made."
    exit 0
  fi
fi

# Prevent first-run bq welcome prompt in fresh Cloud Shell sessions
touch "${HOME}/.bigqueryrc"

echo ""
echo "[1/5] Enabling Vertex AI API & initializing P4SA in ${MODEL_QUOTA_PROJECT_ID}..."
run_cmd gcloud services enable aiplatform.googleapis.com \
  --project="${MODEL_QUOTA_PROJECT_ID}" --quiet
run_cmd gcloud beta services identity create \
  --service=aiplatform.googleapis.com \
  --project="${MODEL_QUOTA_PROJECT_ID}" --quiet

PROJECT_NUMBER=$(gcloud projects describe "${MODEL_QUOTA_PROJECT_ID}" --format="value(projectNumber)")
P4SA_EMAIL="service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com"
echo "  -> Vertex AI P4SA: ${P4SA_EMAIL}"

echo ""
echo "[2/5] Enabling BigQuery API & ensuring US dataset ${AUDIT_LOGGING_PROJECT_ID}:${BQ_DATASET_ID}..."
run_cmd gcloud services enable bigquery.googleapis.com \
  --project="${AUDIT_LOGGING_PROJECT_ID}" --quiet

if bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" show --dataset "${AUDIT_LOGGING_PROJECT_ID}:${BQ_DATASET_ID}" >/dev/null 2>&1; then
  ACTUAL_LOC=$(bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" show --format=json "${AUDIT_LOGGING_PROJECT_ID}:${BQ_DATASET_ID}" | python3 -c "import sys,json; print(json.load(sys.stdin)['location'])")
  if [[ "${ACTUAL_LOC}" != "${DATASET_LOCATION}" ]]; then
    echo "ERROR: Existing dataset '${BQ_DATASET_ID}' is in '${ACTUAL_LOC}', but '${DATASET_LOCATION}' is required for global endpoint logging." >&2
    exit 1
  fi
  echo "  -> Dataset already exists in ${DATASET_LOCATION}."
else
  run_cmd bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" mk \
    --dataset \
    --location="${DATASET_LOCATION}" \
    --description="Central Vertex AI global request/response audit logs (Gemini OrangeBox)" \
    "${AUDIT_LOGGING_PROJECT_ID}:${BQ_DATASET_ID}"
fi

echo ""
echo "[3/5] Granting BigQuery IAM permissions on ${AUDIT_LOGGING_PROJECT_ID} to ${P4SA_EMAIL}..."
run_cmd gcloud projects add-iam-policy-binding "${AUDIT_LOGGING_PROJECT_ID}" \
  --member="serviceAccount:${P4SA_EMAIL}" \
  --role="roles/bigquery.user" \
  --condition=None \
  --quiet >/dev/null

run_cmd gcloud projects add-iam-policy-binding "${AUDIT_LOGGING_PROJECT_ID}" \
  --member="serviceAccount:${P4SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" \
  --condition="expression=resource.name.startsWith('projects/${AUDIT_LOGGING_PROJECT_ID}/datasets/${BQ_DATASET_ID}'),title=OrangeBoxGenAILogsDataEditor,description=Allow ${MODEL_QUOTA_PROJECT_ID} Vertex AI P4SA to write logs to ${BQ_DATASET_ID}" \
  --quiet >/dev/null

echo ""
echo "[4/5] Configuring global publisher logging (100% + OTel)..."
if [[ "${DRY_RUN}" == "true" ]]; then
  for MODEL_ID in "${MODELS[@]}"; do
    MODEL_ID="$(echo "${MODEL_ID}" | xargs)"
    [[ -z "${MODEL_ID}" ]] && continue
    echo "  [dry-run] POST https://aiplatform.googleapis.com/v1beta1/projects/${MODEL_QUOTA_PROJECT_ID}/locations/global/publishers/google/models/${MODEL_ID}:setPublisherModelConfig -> ${BQ_OUTPUT_URI}"
  done
else
  ACCESS_TOKEN=$(gcloud auth print-access-token)
  RESP_FILE=$(mktemp)
  trap 'rm -f "${RESP_FILE}"' EXIT

  for MODEL_ID in "${MODELS[@]}"; do
    MODEL_ID="$(echo "${MODEL_ID}" | xargs)"
    [[ -z "${MODEL_ID}" ]] && continue
    URL="https://aiplatform.googleapis.com/v1beta1/projects/${MODEL_QUOTA_PROJECT_ID}/locations/global/publishers/google/models/${MODEL_ID}:setPublisherModelConfig"
    PAYLOAD=$(cat <<EOF
{
  "publisherModelConfig": {
    "loggingConfig": {
      "enabled": true,
      "samplingRate": 1.0,
      "bigqueryDestination": {
        "outputUri": "${BQ_OUTPUT_URI}"
      },
      "enableOtelLogging": true
    }
  }
}
EOF
)
    HTTP_CODE=$(curl -sS -o "${RESP_FILE}" -w "%{http_code}" \
      -X POST "${URL}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json; charset=utf-8" \
      -H "X-Goog-User-Project: ${MODEL_QUOTA_PROJECT_ID}" \
      -d "${PAYLOAD}")

    if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
      echo "ERROR: Failed to configure ${MODEL_ID} (HTTP ${HTTP_CODE}):" >&2
      cat "${RESP_FILE}" >&2
      exit 1
    fi
    echo "  -> Configured ${MODEL_ID} (HTTP ${HTTP_CODE})"
  done
fi

echo ""
echo "[5/5] Client Caller IAM on ${MODEL_QUOTA_PROJECT_ID}..."
if [[ -n "${CLIENT_CALLER_PRINCIPAL:-}" ]]; then
  run_cmd gcloud projects add-iam-policy-binding "${MODEL_QUOTA_PROJECT_ID}" \
    --member="${CLIENT_CALLER_PRINCIPAL}" \
    --role="roles/aiplatform.user" \
    --condition=None \
    --quiet >/dev/null

  run_cmd gcloud projects add-iam-policy-binding "${MODEL_QUOTA_PROJECT_ID}" \
    --member="${CLIENT_CALLER_PRINCIPAL}" \
    --role="roles/serviceusage.serviceUsageConsumer" \
    --condition=None \
    --quiet >/dev/null
  echo "  -> Granted aiplatform.user + serviceUsageConsumer to ${CLIENT_CALLER_PRINCIPAL}"
else
  echo "  -> Skipped (no Client Caller Principal provided)."
fi

echo ""
echo "======================================================================"
echo "  Setup Complete!"
echo "======================================================================"
echo "Next steps:"
echo "  1. Run a test inference call from your Client Workload Project"
echo "     (see sdk-samples/python/orangebox_client.py or sdk-samples/nodejs/)."
echo "  2. Wait 2-5 minutes for async table creation, then run:"
echo "     ./verify_logging.sh"
echo "======================================================================"

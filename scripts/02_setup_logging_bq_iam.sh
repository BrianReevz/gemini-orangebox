#!/usr/bin/env bash
# Phase B: Create Destination BigQuery Dataset & Assign Cross-Project IAM
# Target: Audit Logging Project + Model & Quota Project P4SA

set -euo pipefail

if [[ -z "${MODEL_QUOTA_PROJECT_ID:-}" ]]; then
  read -r -p "Model & Quota Project ID: " MODEL_QUOTA_PROJECT_ID
fi
if [[ -z "${AUDIT_LOGGING_PROJECT_ID:-}" ]]; then
  read -r -p "Audit Logging Project ID: " AUDIT_LOGGING_PROJECT_ID
fi

DATASET_ID="${BQ_DATASET_ID:-genai_global_logs}"
DATASET_LOCATION="US" # Mandatory: Vertex AI global endpoint requires US multi-region

# Prevent first-run bq initialization prompt in Cloud Shell
touch "${HOME}/.bigqueryrc"

PROJECT_NUMBER=$(gcloud projects describe "${MODEL_QUOTA_PROJECT_ID}" \
  --format="value(projectNumber)")
P4SA_EMAIL="service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com"

echo "Enabling BigQuery API in ${AUDIT_LOGGING_PROJECT_ID}..."
gcloud services enable bigquery.googleapis.com \
  --project="${AUDIT_LOGGING_PROJECT_ID}" --quiet

echo "Creating BigQuery dataset ${AUDIT_LOGGING_PROJECT_ID}:${DATASET_ID} in ${DATASET_LOCATION} multi-region..."
if bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" show --dataset "${AUDIT_LOGGING_PROJECT_ID}:${DATASET_ID}" >/dev/null 2>&1; then
  ACTUAL_LOC=$(bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" show --format=json "${AUDIT_LOGGING_PROJECT_ID}:${DATASET_ID}" | python3 -c "import sys,json; print(json.load(sys.stdin)['location'])")
  if [[ "${ACTUAL_LOC}" != "${DATASET_LOCATION}" ]]; then
    echo "ERROR: Existing dataset ${DATASET_ID} is in '${ACTUAL_LOC}', expected '${DATASET_LOCATION}'." >&2
    exit 1
  fi
  echo "Dataset ${AUDIT_LOGGING_PROJECT_ID}:${DATASET_ID} already exists in ${DATASET_LOCATION}."
else
  bq --quiet --project_id="${AUDIT_LOGGING_PROJECT_ID}" mk \
    --dataset \
    --location="${DATASET_LOCATION}" \
    --description="Central Vertex AI global request/response audit logs (Gemini OrangeBox)" \
    "${AUDIT_LOGGING_PROJECT_ID}:${DATASET_ID}"
fi

echo "Granting roles/bigquery.user on ${AUDIT_LOGGING_PROJECT_ID} to ${P4SA_EMAIL}..."
gcloud projects add-iam-policy-binding "${AUDIT_LOGGING_PROJECT_ID}" \
  --member="serviceAccount:${P4SA_EMAIL}" \
  --role="roles/bigquery.user" \
  --condition=None \
  --quiet >/dev/null

echo "Granting roles/bigquery.dataEditor on ${AUDIT_LOGGING_PROJECT_ID}:${DATASET_ID} to ${P4SA_EMAIL}..."
gcloud projects add-iam-policy-binding "${AUDIT_LOGGING_PROJECT_ID}" \
  --member="serviceAccount:${P4SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" \
  --condition="expression=resource.name.startsWith('projects/${AUDIT_LOGGING_PROJECT_ID}/datasets/${DATASET_ID}'),title=OrangeBoxGenAILogsDataEditor,description=Allow ${MODEL_QUOTA_PROJECT_ID} Vertex AI P4SA to write request/response logs to ${DATASET_ID}" \
  --quiet >/dev/null

echo "Phase B complete: ${P4SA_EMAIL} can write to bq://${AUDIT_LOGGING_PROJECT_ID}.${DATASET_ID}."

#!/usr/bin/env bash
# Phase C: Global Publisher Logging Configurations
# Configures 100% request-response logging + OTel logging on Vertex AI global endpoint

set -euo pipefail

if [[ -z "${MODEL_QUOTA_PROJECT_ID:-}" ]]; then
  read -r -p "Model & Quota Project ID: " MODEL_QUOTA_PROJECT_ID
fi
if [[ -z "${AUDIT_LOGGING_PROJECT_ID:-}" ]]; then
  read -r -p "Audit Logging Project ID: " AUDIT_LOGGING_PROJECT_ID
fi

DATASET_ID="${BQ_DATASET_ID:-genai_global_logs}"
TABLE_ID="${TABLE_ID:-request_response_logging}"

BQ_OUTPUT_URI="bq://${AUDIT_LOGGING_PROJECT_ID}.${DATASET_ID}.${TABLE_ID}"
ENDPOINT="https://aiplatform.googleapis.com/v1beta1"

MODELS=(
  "gemini-4-argon-cyber-permissive"
  "gemini-4-carbon-cyber-permissive"
  "gemini-3.8-flash-cyber"
)

ACCESS_TOKEN=$(gcloud auth print-access-token)
RESP_FILE=$(mktemp)
trap 'rm -f "${RESP_FILE}"' EXIT

for MODEL_ID in "${MODELS[@]}"; do
  echo "Configuring global publisher logging for model: ${MODEL_ID}..."

  URL="${ENDPOINT}/projects/${MODEL_QUOTA_PROJECT_ID}/locations/global/publishers/google/models/${MODEL_ID}:setPublisherModelConfig"

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

  if [[ "${HTTP_CODE}" == "409" ]]; then
    RESP_BODY="$(<"${RESP_FILE}")"
    if [[ "${RESP_BODY}" == *"ALREADY_EXISTS"* && "${RESP_BODY}" == *"same PublisherModelConfig"* ]]; then
      echo "Already configured identically: ${MODEL_ID} -> ${BQ_OUTPUT_URI} (HTTP 409 ALREADY_EXISTS — unchanged)"
      echo ""
      continue
    fi
  fi

  if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
    echo "ERROR: Failed to configure ${MODEL_ID} (HTTP ${HTTP_CODE}):" >&2
    cat "${RESP_FILE}" >&2
    exit 1
  fi

  echo "Successfully configured ${MODEL_ID} -> ${BQ_OUTPUT_URI} (HTTP ${HTTP_CODE})"
  cat "${RESP_FILE}"
  echo ""
done

echo "All Frontier Cyber Models configured for 100% global request-response & OTel logging."

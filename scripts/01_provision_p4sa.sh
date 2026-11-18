#!/usr/bin/env bash
# Phase A: Retrieve & Provision the Project-Level Identity (P4SA)
# Target: Model & Quota Project

set -euo pipefail

if [[ -z "${MODEL_QUOTA_PROJECT_ID:-}" ]]; then
  read -r -p "Model & Quota Project ID: " MODEL_QUOTA_PROJECT_ID
fi

echo "Enabling Vertex AI API (aiplatform.googleapis.com) in ${MODEL_QUOTA_PROJECT_ID}..."
gcloud services enable aiplatform.googleapis.com \
  --project="${MODEL_QUOTA_PROJECT_ID}" --quiet

echo "Initializing Vertex AI Platform-Level Service Agent (P4SA) in ${MODEL_QUOTA_PROJECT_ID}..."
gcloud beta services identity create \
  --service=aiplatform.googleapis.com \
  --project="${MODEL_QUOTA_PROJECT_ID}" --quiet

PROJECT_NUMBER=$(gcloud projects describe "${MODEL_QUOTA_PROJECT_ID}" \
  --format="value(projectNumber)")

if [[ -z "${PROJECT_NUMBER}" ]]; then
  echo "ERROR: Failed to retrieve project number for ${MODEL_QUOTA_PROJECT_ID}." >&2
  exit 1
fi

P4SA_EMAIL="service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com"

echo "------------------------------------------------------------"
echo "Model & Quota Project : ${MODEL_QUOTA_PROJECT_ID}"
echo "Project Number        : ${PROJECT_NUMBER}"
echo "Vertex AI P4SA Email  : ${P4SA_EMAIL}"
echo "------------------------------------------------------------"

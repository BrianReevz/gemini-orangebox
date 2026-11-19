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

run_cmd_quiet() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [dry-run] $*"
  else
    "$@" >/dev/null
  fi
}

trim_whitespace() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

normalize_iam_principal() {
  local LC_ALL=C
  local _raw="$1"
  local _out_var="$2"
  local item lower prefix lower_prefix val normalized

  item="$(trim_whitespace "${_raw}")"
  if [[ ( "${item}" == \"*\" && "${#item}" -ge 2 ) || ( "${item}" == \'*\' && "${#item}" -ge 2 ) ]]; then
    item="${item:1:${#item}-2}"
    item="$(trim_whitespace "${item}")"
  fi

  if [[ -z "${item}" ]]; then
    echo "  ERROR: Principal entry cannot be empty." >&2
    return 1
  fi

  local re_space='[[:space:]]'
  local re_email='^[A-Za-z0-9._%+'\''-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
  local re_domain='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
  local re_gsa='\.gserviceaccount\.com$'
  local re_k8s_sa='\.svc\.id\.goog\[.+\]$'
  local re_uri_host='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
  local re_uri_bad_chars='[[:space:][:cntrl:]"'\''`;]'

  lower="$(printf '%s' "${item}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

  if [[ "${lower}" == "allusers" || "${lower}" == "allauthenticatedusers" ]]; then
    echo "  ERROR: Public principal '${item}' is disallowed on project IAM policies." >&2
    return 1
  fi
  if [[ "${lower}" == deleted:* ]]; then
    echo "  ERROR: Deleted principal '${item}' cannot be bound to an IAM policy." >&2
    return 1
  fi

  # Federated / principal-set URIs (principal://... or principalSet://...)
  if [[ "${item}" == *"://"* ]]; then
    local uri_scheme uri_rest lower_scheme lower_rest canon_scheme uri_host uri_path
    uri_scheme="$(trim_whitespace "${item%%://*}")"
    uri_rest="$(trim_whitespace "${item#*://}")"
    lower_scheme="$(printf '%s' "${uri_scheme}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    lower_rest="$(printf '%s' "${uri_rest}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

    case "${lower_scheme}" in
      principal)    canon_scheme="principal" ;;
      principalset) canon_scheme="principalSet" ;;
      *)
        echo "  ERROR: Unsupported principal URI scheme '${uri_scheme}://' in '${item}'. Expected 'principal://' or 'principalSet://'." >&2
        return 1
        ;;
    esac

    if [[ "${lower_rest}" == "goog/public:"* ]]; then
      echo "  ERROR: Public principal '${item}' is disallowed on project IAM policies." >&2
      return 1
    fi

    if [[ "${uri_rest}" != */* || "${uri_rest}" =~ ${re_uri_bad_chars} ]]; then
      echo "  ERROR: Invalid '${canon_scheme}://' identifier '${item}'. Expected format like '${canon_scheme}://iam.googleapis.com/...'." >&2
      return 1
    fi

    uri_host="${uri_rest%%/*}"
    uri_path="${uri_rest#*/}"

    if [[ ! "${uri_host}" =~ ${re_uri_host} || -z "${uri_path}" || "${uri_path}" == /* || "${uri_path}" == */ ]]; then
      echo "  ERROR: Invalid '${canon_scheme}://' identifier '${item}'. Expected format like '${canon_scheme}://iam.googleapis.com/...'." >&2
      return 1
    fi

    if [[ "${canon_scheme}" == "principal" && ( "${uri_path}" == "*" || "${uri_path}" == *"/*" ) ]]; then
      echo "  ERROR: Wildcard '/*' in '${item}' requires 'principalSet://', not 'principal://'." >&2
      return 1
    fi

    normalized="${canon_scheme}://${uri_rest}"
    if [[ "${normalized}" != "${item}" ]]; then
      echo "  Note: Normalized principal '${item}' -> '${normalized}'." >&2
    fi
    printf -v "${_out_var}" '%s' "${normalized}"
    return 0
  fi

  # Standard <type>:<value> principals
  if [[ "${item}" == *:* ]]; then
    prefix="$(trim_whitespace "${item%%:*}")"
    val="$(trim_whitespace "${item#*:}")"
    lower_prefix="$(printf '%s' "${prefix}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

    local canon_prefix=""
    case "${lower_prefix}" in
      user)           canon_prefix="user" ;;
      serviceaccount) canon_prefix="serviceAccount" ;;
      group)          canon_prefix="group" ;;
      domain)         canon_prefix="domain" ;;
      principal|principalset)
        echo "  ERROR: Invalid principal '${item}'. Federated principals must use 'principal://...' or 'principalSet://...'." >&2
        return 1
        ;;
      *)
        echo "  ERROR: Invalid principal type '${prefix}' in '${item}'. Allowed prefixes: user:, serviceAccount:, group:, domain:, principal://, principalSet://." >&2
        return 1
        ;;
    esac

    if [[ -z "${val}" ]]; then
      echo "  ERROR: Missing identifier after '${canon_prefix}:' in '${item}'." >&2
      return 1
    fi
    if [[ "${val}" =~ ${re_space} || "${val}" == *:* ]]; then
      echo "  ERROR: Invalid identifier '${val}' in '${item}' (must not contain spaces or colons)." >&2
      return 1
    fi

    local lower_val
    lower_val="$(printf '%s' "${val}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

    case "${canon_prefix}" in
      serviceAccount)
        if [[ "${lower_val}" =~ ${re_k8s_sa} ]]; then
          echo "  ERROR: GKE Workload Identity '${item}' cannot be bound directly to a project IAM policy. Use 'serviceAccount:<sa>@<project>.iam.gserviceaccount.com' or 'principal://iam.googleapis.com/...'." >&2
          return 1
        fi
        if [[ ! "${val}" =~ ${re_email} || ! "${lower_val}" =~ ${re_gsa} ]]; then
          echo "  ERROR: Invalid service account email '${val}'. Expected '<name>@<project>.iam.gserviceaccount.com' (or use 'user:' / 'group:' for non-service-account emails)." >&2
          return 1
        fi
        ;;
      user|group)
        if [[ "${lower_val}" =~ ${re_gsa} ]]; then
          echo "  ERROR: '${val}' is a Google Cloud service account email; use 'serviceAccount:${val}' instead of '${canon_prefix}:${val}'." >&2
          return 1
        fi
        if [[ ! "${val}" =~ ${re_email} ]]; then
          echo "  ERROR: Invalid email address '${val}' for '${canon_prefix}:'. Expected '${canon_prefix}:name@example.com'." >&2
          return 1
        fi
        ;;
      domain)
        if [[ "${val}" == *@* ]]; then
          echo "  ERROR: 'domain:' expects a domain name (e.g. 'domain:example.com'), not an email address '${val}'." >&2
          return 1
        fi
        if [[ ! "${val}" =~ ${re_domain} ]]; then
          echo "  ERROR: Invalid domain '${val}' in '${item}'. Expected format 'domain:example.com'." >&2
          return 1
        fi
        ;;
    esac

    normalized="${canon_prefix}:${val}"
    if [[ "${normalized}" != "${item}" ]]; then
      echo "  Note: Normalized principal '${item}' -> '${normalized}'." >&2
    fi
    printf -v "${_out_var}" '%s' "${normalized}"
    return 0
  fi

  # Bare identifier without '<type>:' prefix
  if [[ "${lower}" =~ ${re_k8s_sa} ]]; then
    echo "  ERROR: GKE Workload Identity '${item}' cannot be bound directly to a project IAM policy. Use 'serviceAccount:<sa>@<project>.iam.gserviceaccount.com' or 'principal://iam.googleapis.com/...'." >&2
    return 1
  fi

  if [[ "${item}" =~ ${re_email} ]]; then
    if [[ "${lower}" =~ ${re_gsa} ]]; then
      normalized="serviceAccount:${item}"
      echo "  Note: Auto-prefixed service account email as '${normalized}'." >&2
    elif [[ "${lower}" == *@googlegroups.com ]]; then
      normalized="group:${item}"
      echo "  Note: Auto-prefixed Google Group email as '${normalized}'." >&2
    else
      normalized="user:${item}"
      echo "  Note: Auto-prefixed bare email as '${normalized}' (use 'group:${item}' if this is a Google Group)." >&2
    fi
    printf -v "${_out_var}" '%s' "${normalized}"
    return 0
  fi

  if [[ "${item}" =~ ${re_domain} ]]; then
    echo "  ERROR: Bare domain '${item}' is ambiguous. Specify 'domain:${item}' explicitly to grant domain-wide access, or provide an email / '<type>:<value>' principal." >&2
    return 1
  fi

  echo "  ERROR: Invalid Client Caller Principal '${item}'. Expected '<type>:<value>' (e.g. 'user:you@example.com' or 'serviceAccount:app@project.iam.gserviceaccount.com') or a full email address." >&2
  return 1
}

CLIENT_CALLER_PRINCIPALS=()

parse_caller_principals() {
  local LC_ALL=C
  local raw_csv="$1"
  local trimmed
  CLIENT_CALLER_PRINCIPALS=()

  if [[ "${raw_csv}" == *$'\n'* || "${raw_csv}" == *$'\r'* ]]; then
    echo "  ERROR: Client Caller Principal must not contain newline characters." >&2
    return 1
  fi

  trimmed="$(trim_whitespace "${raw_csv}")"
  if [[ -z "${trimmed}" ]]; then
    return 0
  fi

  if [[ "${trimmed}" == \"*\" && "${#trimmed}" -ge 2 ]]; then
    local inner="${trimmed:1:${#trimmed}-2}"
    if [[ "${inner}" != *\"* ]]; then
      trimmed="$(trim_whitespace "${inner}")"
    fi
  elif [[ "${trimmed}" == \'*\' && "${#trimmed}" -ge 2 ]]; then
    local inner="${trimmed:1:${#trimmed}-2}"
    if [[ "${inner}" != *\'* ]]; then
      trimmed="$(trim_whitespace "${inner}")"
    fi
  fi

  if [[ -z "${trimmed}" ]]; then
    return 0
  fi

  if [[ "${trimmed}" == ,* || "${trimmed}" == *, || "${trimmed}" == *,,* ]]; then
    echo "  ERROR: Empty principal entry in '${raw_csv}'." >&2
    return 1
  fi

  local raw_items=()
  IFS=',' read -r -a raw_items <<< "${trimmed}"

  local re_rdn='^[A-Za-z][A-Za-z0-9-]*=[^[:space:]:@/'\''"]+['\''"]?$'
  local re_prev_uri='^['\''"]?(principal|principalset)://'
  local re_prev_end_bad='[[:space:]"'\'']'
  local merged_items=()
  local part prev prev_lower prev_end last_idx
  for part in "${raw_items[@]}"; do
    if [[ -z "$(trim_whitespace "${part}")" ]]; then
      echo "  ERROR: Empty principal entry in '${raw_csv}'." >&2
      return 1
    fi
    if [[ "${#merged_items[@]}" -gt 0 && "${part}" =~ ${re_rdn} ]]; then
      last_idx=$(( ${#merged_items[@]} - 1 ))
      prev="${merged_items[${last_idx}]}"
      prev_lower="$(printf '%s' "$(trim_whitespace "${prev}")" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      prev_end="${prev:${#prev}-1:1}"
      if [[ "${prev_lower}" =~ ${re_prev_uri} && ! "${prev_end}" =~ ${re_prev_end_bad} ]]; then
        merged_items[${last_idx}]="${prev},${part}"
        continue
      fi
    fi
    merged_items+=("${part}")
  done

  local entry norm existing dup
  for entry in "${merged_items[@]}"; do
    if ! normalize_iam_principal "${entry}" norm; then
      CLIENT_CALLER_PRINCIPALS=()
      return 1
    fi
    dup=false
    for existing in "${CLIENT_CALLER_PRINCIPALS[@]+"${CLIENT_CALLER_PRINCIPALS[@]}"}"; do
      if [[ "${existing}" == "${norm}" ]]; then
        dup=true
        break
      fi
    done
    if [[ "${dup}" == "false" ]]; then
      CLIENT_CALLER_PRINCIPALS+=("${norm}")
    fi
  done
  return 0
}

prompt_caller_principals() {
  local prompt_text="$1"

  if [[ -n "${CLIENT_CALLER_PRINCIPAL+x}" ]]; then
    if ! parse_caller_principals "${CLIENT_CALLER_PRINCIPAL}"; then
      exit 1
    fi
    return 0
  fi

  local input=""
  local had_error=false
  while true; do
    if ! read -r -p "${prompt_text} (press Enter to skip): " input; then
      if [[ "${had_error}" == "true" ]]; then
        echo "  ERROR: Aborting due to invalid Client Caller Principal." >&2
        exit 1
      fi
      CLIENT_CALLER_PRINCIPALS=()
      return 0
    fi
    if parse_caller_principals "${input}"; then
      return 0
    fi
    had_error=true
    echo "  Please try again, or press Enter to skip." >&2
  done
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="${3:-}"
  local current_val
  current_val="$(trim_whitespace "${!var_name:-}")"

  if [[ -n "${current_val}" ]]; then
    printf -v "${var_name}" '%s' "${current_val}"
    return 0
  fi

  local input=""
  while true; do
    if [[ -n "${default_val}" ]]; then
      if ! read -r -p "${prompt_text} [${default_val}]: " input; then
        echo "ERROR: Unexpected end of input reading ${var_name}." >&2
        exit 1
      fi
      input="$(trim_whitespace "${input}")"
      input="${input:-${default_val}}"
    else
      if ! read -r -p "${prompt_text}: " input; then
        echo "ERROR: Unexpected end of input reading ${var_name}." >&2
        exit 1
      fi
      input="$(trim_whitespace "${input}")"
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

  if [[ -n "${!var_name+x}" ]]; then
    printf -v "${var_name}" '%s' "$(trim_whitespace "${!var_name}")"
    return 0
  fi

  local input=""
  if ! read -r -p "${prompt_text} (press Enter to skip): " input; then
    input=""
  fi
  printf -v "${var_name}" '%s' "$(trim_whitespace "${input}")"
}

echo "======================================================================"
echo "  Gemini OrangeBox — Multi-Project Vertex AI & BigQuery Audit Setup"
echo "======================================================================"
echo ""

prompt_required MODEL_QUOTA_PROJECT_ID "1) Model & Quota Project ID (hosts allowlisted models & P4SA)"
prompt_required AUDIT_LOGGING_PROJECT_ID "2) Audit Logging Project ID (hosts central BigQuery dataset)"
prompt_required BQ_DATASET_ID "3) BigQuery Dataset ID (created in US multi-region)" "genai_global_logs"
prompt_optional CLIENT_WORKLOAD_PROJECT_ID "4) Client Workload Project ID (for reference, optional)"
prompt_caller_principals "5) Client Caller Principal(s) to grant inference access (e.g. user:you@example.com or serviceAccount:app@proj.iam.gserviceaccount.com)"
prompt_required MODELS_CSV "6) Comma-separated global model IDs" "${DEFAULT_MODELS_CSV}"

RAW_MODELS=()
IFS=',' read -r -a RAW_MODELS <<< "${MODELS_CSV}"
MODELS=()
for raw_model in "${RAW_MODELS[@]+"${RAW_MODELS[@]}"}"; do
  trimmed_model="$(trim_whitespace "${raw_model}")"
  if [[ -n "${trimmed_model}" ]]; then
    MODELS+=("${trimmed_model}")
  fi
done
if [[ "${#MODELS[@]}" -eq 0 ]]; then
  echo "ERROR: MODELS_CSV must contain at least one model ID." >&2
  exit 1
fi

echo ""
echo "Validating project access..."
for proj in "${MODEL_QUOTA_PROJECT_ID}" "${AUDIT_LOGGING_PROJECT_ID}"; do
  if ! gcloud projects describe "${proj}" --format="value(projectId)" >/dev/null 2>&1; then
    echo "ERROR: Cannot access project '${proj}'. Check the project ID and your permissions." >&2
    exit 1
  fi
done

BQ_OUTPUT_URI="bq://${AUDIT_LOGGING_PROJECT_ID}.${BQ_DATASET_ID}.${TABLE_ID}"

CALLER_DISPLAY="(skipped)"
if [[ -n "${CLIENT_CALLER_PRINCIPALS[0]+x}" ]]; then
  printf -v CALLER_DISPLAY '%s, ' "${CLIENT_CALLER_PRINCIPALS[@]}"
  CALLER_DISPLAY="${CALLER_DISPLAY%, }"
fi

echo ""
echo "------------------------- Review Configuration -------------------------"
echo "Model & Quota Project   : ${MODEL_QUOTA_PROJECT_ID}"
echo "Audit Logging Project   : ${AUDIT_LOGGING_PROJECT_ID}"
echo "BigQuery Destination    : ${BQ_OUTPUT_URI} (location=${DATASET_LOCATION})"
if [[ -n "${CLIENT_WORKLOAD_PROJECT_ID:-}" ]]; then
  echo "Client Workload Project : ${CLIENT_WORKLOAD_PROJECT_ID}"
fi
echo "Client Caller Principal : ${CALLER_DISPLAY}"
echo "In-Scope Models (global): ${MODELS[*]}"
echo "------------------------------------------------------------------------"
echo ""

if [[ "${AUTO_APPROVE:-false}" != "true" && "${DRY_RUN}" != "true" ]]; then
  confirm=""
  if ! read -r -p "Proceed with this configuration? [y/N]: " confirm; then
    echo ""
    echo "Aborted. No changes were made."
    exit 0
  fi
  confirm="$(trim_whitespace "${confirm}")"
  if [[ ! "${confirm}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
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
run_cmd_quiet gcloud projects add-iam-policy-binding "${AUDIT_LOGGING_PROJECT_ID}" \
  --member="serviceAccount:${P4SA_EMAIL}" \
  --role="roles/bigquery.user" \
  --condition=None \
  --quiet

run_cmd_quiet gcloud projects add-iam-policy-binding "${AUDIT_LOGGING_PROJECT_ID}" \
  --member="serviceAccount:${P4SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" \
  --condition="expression=resource.name.startsWith('projects/${AUDIT_LOGGING_PROJECT_ID}/datasets/${BQ_DATASET_ID}'),title=OrangeBoxGenAILogsDataEditor,description=Allow ${MODEL_QUOTA_PROJECT_ID} Vertex AI P4SA to write logs to ${BQ_DATASET_ID}" \
  --quiet

echo ""
echo "[4/5] Configuring global publisher logging (100% + OTel)..."
if [[ "${DRY_RUN}" == "true" ]]; then
  for MODEL_ID in "${MODELS[@]}"; do
    echo "  [dry-run] POST https://aiplatform.googleapis.com/v1beta1/projects/${MODEL_QUOTA_PROJECT_ID}/locations/global/publishers/google/models/${MODEL_ID}:setPublisherModelConfig -> ${BQ_OUTPUT_URI}"
  done
else
  ACCESS_TOKEN=$(gcloud auth print-access-token)
  RESP_FILE=$(mktemp)
  trap 'rm -f "${RESP_FILE}"' EXIT

  for MODEL_ID in "${MODELS[@]}"; do
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
if [[ -n "${CLIENT_CALLER_PRINCIPALS[0]+x}" ]]; then
  for PRINCIPAL in "${CLIENT_CALLER_PRINCIPALS[@]}"; do
    run_cmd_quiet gcloud projects add-iam-policy-binding "${MODEL_QUOTA_PROJECT_ID}" \
      --member="${PRINCIPAL}" \
      --role="roles/aiplatform.user" \
      --condition=None \
      --quiet

    run_cmd_quiet gcloud projects add-iam-policy-binding "${MODEL_QUOTA_PROJECT_ID}" \
      --member="${PRINCIPAL}" \
      --role="roles/serviceusage.serviceUsageConsumer" \
      --condition=None \
      --quiet
    echo "  -> Granted aiplatform.user + serviceUsageConsumer to ${PRINCIPAL}"
  done
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

# Phase A: Model & Quota Project API & Vertex AI P4SA
resource "google_project_service" "aiplatform" {
  project            = var.model_project_id
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service_identity" "aiplatform_p4sa" {
  provider = google-beta
  project  = var.model_project_id
  service  = "aiplatform.googleapis.com"

  depends_on = [google_project_service.aiplatform]
}

# Phase B: Audit Logging Project API, US Dataset & Cross-Project P4SA IAM
resource "google_project_service" "bigquery" {
  project            = var.logging_project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_bigquery_dataset" "genai_global_logs" {
  project                    = var.logging_project_id
  dataset_id                 = var.bq_dataset_id
  friendly_name              = "Gemini OrangeBox Global Request-Response Logs"
  description                = "Central audit dataset for global Vertex AI models (pinned to US multi-region)."
  location                   = "US" # Mandatory: Vertex AI global endpoint requires US multi-region
  delete_contents_on_destroy = false

  labels = {
    component   = "gemini-orangebox"
    environment = "audit"
    managed_by  = "terraform"
  }

  depends_on = [google_project_service.bigquery]
}

resource "google_project_iam_member" "p4sa_bq_user" {
  project = var.logging_project_id
  role    = "roles/bigquery.user"
  member  = google_project_service_identity.aiplatform_p4sa.member
}

resource "google_bigquery_dataset_iam_member" "p4sa_bq_data_editor" {
  project    = var.logging_project_id
  dataset_id = google_bigquery_dataset.genai_global_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_project_service_identity.aiplatform_p4sa.member
}

# Client Workload Caller Cross-Project Inference & Quota Routing Permissions
resource "google_project_iam_member" "client_aiplatform_user" {
  for_each = toset(var.client_caller_members)

  project = var.model_project_id
  role    = "roles/aiplatform.user"
  member  = each.value
}

resource "google_project_iam_member" "client_service_usage_consumer" {
  for_each = toset(var.client_caller_members)

  project = var.model_project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = each.value
}

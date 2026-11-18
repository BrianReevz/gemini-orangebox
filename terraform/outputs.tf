output "vertex_ai_p4sa_email" {
  description = "Global Vertex AI Service Agent (P4SA) email for the central model project."
  value       = google_project_service_identity.aiplatform_p4sa.email
}

output "bigquery_logging_destination_uri" {
  description = "BigQuery destination URI for setPublisherModelConfig."
  value       = "bq://${var.logging_project_id}.${google_bigquery_dataset.genai_global_logs.dataset_id}.request_response_logging"
}

output "bigquery_dataset_location" {
  description = "Confirmed BigQuery dataset location (must be US)."
  value       = google_bigquery_dataset.genai_global_logs.location
}

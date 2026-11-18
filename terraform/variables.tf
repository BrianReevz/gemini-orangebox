variable "model_project_id" {
  description = "Model & Quota Project ID hosting the allowlisted Vertex AI models and P4SA."
  type        = string
}

variable "logging_project_id" {
  description = "Audit Logging Project ID hosting the central US multi-region BigQuery dataset."
  type        = string
}

variable "bq_dataset_id" {
  description = "BigQuery dataset ID for global Vertex AI request/response logs."
  type        = string
  default     = "genai_global_logs"
}

variable "client_caller_members" {
  description = "IAM members (e.g., serviceAccount:app@my-client-workload-project.iam.gserviceaccount.com) allowed to invoke models and route quota to model_project_id."
  type        = list(string)
  default     = []
}

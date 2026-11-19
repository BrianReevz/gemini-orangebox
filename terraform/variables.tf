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
  description = "IAM members (e.g., user:you@example.com or serviceAccount:app@my-client-workload-project.iam.gserviceaccount.com) allowed to invoke models and route quota to model_project_id."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for m in var.client_caller_members : (
        m != null && trimspace(m) == m && length(m) > 0 && !can(regex("[\\s\\x00-\\x1f\\x7f]", m)) && (
          (
            can(regex("^serviceAccount:[A-Za-z0-9._%+'-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$", m)) &&
            endswith(lower(m), ".gserviceaccount.com")
            ) || (
            can(regex("^(user|group):[A-Za-z0-9._%+'-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$", m)) &&
            !endswith(lower(m), ".gserviceaccount.com")
          ) ||
          can(regex("^domain:[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$", m)) || (
            can(regex("^(principal|principalSet)://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*/[^/\\s\"'`;]([^\\s\"'`;]*[^/\\s\"'`;])?$", m)) &&
            !startswith(lower(m), "principalset://goog/public:") &&
            !startswith(lower(m), "principal://goog/public:") &&
            !(startswith(m, "principal://") && endswith(m, "/*"))
          )
        )
      )
    ])
    error_message = "Each entry in client_caller_members must include a valid IAM principal prefix ('user:<email>', 'serviceAccount:<sa>@<project>.iam.gserviceaccount.com', 'group:<email>', 'domain:<domain>', 'principal://...', or 'principalSet://...')."
  }
}

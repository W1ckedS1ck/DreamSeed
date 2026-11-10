variable "grafana_cloud_url" {
  description = "Grafana Cloud instance URL (e.g. https://vitalikuts.grafana.net)"
  type        = string
}

variable "grafana_cloud_token" {
  description = "Grafana Cloud Service Account token (glsa_*)"
  type        = string
  sensitive   = true
}

variable "sm_access_token" {
  description = "Synthetic Monitoring access token (falls back to grafana_cloud_token)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sm_enabled" {
  description = "Enable Synthetic Monitoring checks"
  type        = bool
  default     = true
}

variable "domains" {
  description = "Domains to monitor (e.g. [\"dreamseed.online\"] or [\"aws.vitalikuts.online\", \"hetz.vitalikuts.online\"])"
  type        = list(string)

  validation {
    condition     = alltrue([for d in var.domains : can(regex("^[A-Za-z0-9.-]+$", d))])
    error_message = "Each domain must contain only letters, digits, dots, and hyphens."
  }
}

variable "sm_url" {
  description = "Synthetic Monitoring API URL (e.g. https://synthetic-monitoring-api-eu-north-0.grafana.net)"
  type        = string
  default     = ""
}

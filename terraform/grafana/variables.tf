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
  default     = false
}

variable "domain" {
  description = "Domain to monitor (e.g. dreamseed.online)"
  type        = string
  default     = "dreamseed.online"
}



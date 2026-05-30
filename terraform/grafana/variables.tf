variable "grafana_cloud_url" {
  description = "Grafana Cloud URL"
  type        = string
  sensitive   = true
}

variable "grafana_cloud_username" {
  description = "Grafana Cloud username (org ID)"
  type        = string
  sensitive   = true
}

variable "grafana_cloud_token" {
  description = "Grafana Cloud API token"
  type        = string
  sensitive   = true
}

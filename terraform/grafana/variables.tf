variable "grafana_cloud_url" {
  description = "Grafana Cloud instance URL (e.g. https://vitalikuts.grafana.net)"
  type        = string
}

variable "grafana_cloud_token" {
  description = "Grafana Cloud Service Account token (glsa_*)"
  type        = string
  sensitive   = true
}

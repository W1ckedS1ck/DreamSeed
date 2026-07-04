variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:Cache Rules permission"
  type        = string
  sensitive   = true
}

variable "zone_name" {
  description = "Cloudflare zone name (domain)"
  type        = string
}

variable "edge_ttl" {
  description = "Edge TTL in seconds for cached HTML"
  type        = number
  default     = 3600
}

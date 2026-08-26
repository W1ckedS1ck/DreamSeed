variable "cloudflare_api_token" {
  description = "Cloudflare API token"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Full domain (e.g., aws.vitalikuts.online or vitalikuts.online)"
  type        = string
}

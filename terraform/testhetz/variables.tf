variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token"
}

variable "server_type" {
  type        = string
  description = "Hetzner server type (cx33, cax21, etc.)"
}

variable "location" {
  type        = string
  description = "Hetzner datacenter location"
  default     = "fsn1"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key content to inject"
}

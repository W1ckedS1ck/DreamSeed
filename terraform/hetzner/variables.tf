variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token"
}

variable "ssh_key_name" {
  type        = string
  description = "Name of an existing SSH key in Hetzner Cloud. Empty = create from ssh_public_key"
  default     = ""
}

variable "ssh_public_key" {
  type        = string
  description = "Public key content (used when ssh_key_name is empty)"
  default     = ""
}

variable "primary_ip_name" {
  type        = string
  description = "Name of the existing Primary IP in Hetzner Cloud. Empty = dynamic IP"
  default     = ""
}

variable "environment" {
  description = "Deployment environment (prod, dev-hetz, etc.) — used in resource names to avoid conflicts"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type (cx23, cx33, etc.)"
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner datacenter location (nbg1, fsn1, hel1, etc.)"
  type        = string
  default     = "nbg1"
}

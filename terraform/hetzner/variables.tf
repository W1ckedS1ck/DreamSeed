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

  validation {
    condition     = can(regex("^(prod|dev|test)(-[a-z]+)?$", var.environment))
    error_message = "Must match {type}[-{provider}], e.g. prod, dev-aws, prod-hetz, test"
  }
}

variable "server_type" {
  description = "Hetzner server type (cx23, cx33, etc.)"
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner datacenter location (nbg1, fsn1, hel1, ash)"
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash"], var.location)
    error_message = "Must be one of: nbg1, fsn1, hel1, ash"
  }
}

variable "ubuntu_pro_token" {
  description = "Ubuntu Pro token for ESM (auto-attach on first boot)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "additional_ssh_keys" {
  type        = list(string)
  description = "Additional SSH public keys to inject via cloud-init (in addition to ssh_public_key)"
  default     = []
}

variable "enable_primary_ip" {
  type        = bool
  description = "Create a new Primary IP in Hetzner Cloud (only when primary_ip_name is empty)"
  default     = false
}

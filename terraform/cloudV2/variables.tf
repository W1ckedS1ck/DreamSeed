variable "project_id" {
  type        = string
  description = "Cloud.ru Project ID"
  default     = "5b56cd22-ab6c-4857-8009-6efb7c04321c"
}

variable "auth_key_id" {
  type        = string
  description = "Cloud.ru Service Account Auth Key ID"
  sensitive   = true
}

variable "auth_secret" {
  type        = string
  description = "Cloud.ru Service Account Auth Secret"
  sensitive   = true
}

variable "instance_name" {
  type        = string
  description = "Instance name"
  default     = "DreamSeed"
}

variable "zone" {
  type        = string
  description = "Availability zone"
  default     = "ru.AZ-1"
}

variable "flavor" {
  type        = string
  description = "Instance flavor"
  default     = "gen-1-1"
}

variable "ssh_key_name" {
  type        = string
  description = "SSH key name"
  default     = "vitali"
}

variable "subnet_name" {
  type        = string
  description = "Subnet name to attach interface to"
  default     = "default"
}

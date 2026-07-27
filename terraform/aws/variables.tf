variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
}

variable "disable_auto_public_ip" {
  description = "Set to true to prevent AWS from auto-assigning a public IP (use when attaching an EIP via aws_eip_association outside this module, or managing it manually). Default false."
  type        = bool
  default     = false
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "ubuntu_pro_token" {
  description = "Ubuntu Pro token for ESM (auto-attach on first boot)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "additional_ssh_keys" {
  description = "Additional SSH public keys to inject via cloud-init (in addition to the deploy key)"
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Deployment environment (prod, dev-aws, etc.) — used in resource names to avoid conflicts"
  type        = string

  validation {
    condition     = can(regex("^(prod|dev|test)(-[a-z]+)?$", var.environment))
    error_message = "Must match {type}[-{provider}], e.g. prod, dev-aws, prod-hetz, test"
  }
}

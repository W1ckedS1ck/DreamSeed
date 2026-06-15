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

variable "elastic_ip_allocation_id" {
  description = "Allocation ID of an existing Elastic IP to associate. Leave empty to skip EIP association."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "environment" {
  description = "Deployment environment (prod, dev-aws, etc.) — used in resource names to avoid conflicts"
  type        = string

  validation {
    condition     = can(regex("^(prod|dev|test)(-[a-z]+)?$", var.environment))
    error_message = "Must match {type}[-{provider}], e.g. prod, dev-aws, prod-hetz, test"
  }
}

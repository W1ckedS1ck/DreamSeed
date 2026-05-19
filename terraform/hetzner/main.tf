terraform {
  required_version = ">= 1.1"

  backend "remote" {
    organization = "Dreamseed"
    workspaces {
      prefix = "dreamseed-"
    }
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.63"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "ssh_key_name" {
  type        = string
  description = "Name of an existing SSH key in Hetzner Cloud. Empty = create from ssh_public_key"
  default     = "Vitali"
}

variable "ssh_public_key" {
  type        = string
  description = "Public key content (used when ssh_key_name is empty)"
  default     = ""
}

variable "primary_ip_name" {
  type        = string
  description = "Name of the existing Primary IP in Hetzner Cloud. Empty = dynamic IP"
  default     = "primary_ip-1"
}

variable "environment" {
  description = "Deployment environment (prod, dev-hetz, etc.) — used in resource names to avoid conflicts"
  type        = string
  default     = "prod"
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

locals {
  use_dynamic_ip = var.primary_ip_name == ""
  use_existing_key = var.ssh_key_name != ""
}

data "hcloud_ssh_key" "default" {
  count = local.use_existing_key ? 1 : 0
  name  = var.ssh_key_name
}

resource "hcloud_ssh_key" "ci_key" {
  count      = local.use_existing_key ? 0 : 1
  name       = "dreamseed-ci-${var.environment}"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "web" {
  name = "dreamseed-fw-${var.environment}"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0"] # IPv4 only
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0"] # IPv4 only
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0"] # IPv4 only
  }
}

data "hcloud_primary_ip" "main" {
  count = local.use_dynamic_ip ? 0 : 1
  name  = var.primary_ip_name
}

resource "hcloud_server" "main" {
  name         = "dreamseed-${var.environment}"
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = local.use_existing_key ? [data.hcloud_ssh_key.default[0].id] : [hcloud_ssh_key.ci_key[0].id]
  firewall_ids = [hcloud_firewall.web.id]

  public_net {
    ipv4_enabled = true
    ipv4         = local.use_dynamic_ip ? null : data.hcloud_primary_ip.main[0].id
  }

  user_data = <<-EOF
    #!/bin/bash
    useradd -m -s /bin/bash -G sudo ubuntu
    mkdir -p /home/ubuntu/.ssh
    cp /root/.ssh/authorized_keys /home/ubuntu/.ssh/
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu
    echo 'PermitRootLogin no' > /etc/ssh/sshd_config.d/disable-root.conf
    systemctl restart ssh
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  EOF
}

output "server_ipv4" {
  value = hcloud_server.main.ipv4_address
}

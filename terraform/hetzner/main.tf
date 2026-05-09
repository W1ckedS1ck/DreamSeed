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
      version = "~> 1.0"
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
  description = "Name of the SSH key in Hetzner Cloud"
  default     = "Vitali"
}

variable "primary_ip_name" {
  type        = string
  description = "Name of the existing Primary IP in Hetzner Cloud"
  default     = "primary_ip-1"
}

variable "environment" {
  description = "Deployment environment (prod, dev-hetz, etc.) — used in resource names to avoid conflicts"
  type        = string
  default     = "prod"
}

data "hcloud_ssh_key" "default" {
  name = var.ssh_key_name
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
  name = var.primary_ip_name
}

resource "hcloud_server" "main" {
  name         = "dreamseed-${var.environment}"
  server_type  = "cx23"
  image        = "ubuntu-24.04"
  location     = "nbg1"
  ssh_keys     = [data.hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.web.id]

  public_net {
    ipv4_enabled = true
    ipv4         = data.hcloud_primary_ip.main.id
    # ipv6_enabled = true
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

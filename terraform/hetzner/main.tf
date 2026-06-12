locals {
  use_existing_key  = var.ssh_key_name != ""
  use_existing_ip   = var.primary_ip_name != ""
  create_primary_ip = var.primary_ip_name == "" && var.enable_primary_ip
  labels = {
    environment = var.environment
    service     = "DreamSeed"
    managed_by  = "terraform"
  }
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
  name   = "dreamseed-fw-${var.environment}"
  labels = local.labels

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "80-443"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "123"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

data "hcloud_primary_ip" "main" {
  count = local.use_existing_ip ? 1 : 0
  name  = var.primary_ip_name
}

resource "hcloud_primary_ip" "main" {
  count             = local.create_primary_ip ? 1 : 0
  name              = "dreamseed-main-${var.environment}"
  datacenter        = "${var.location}-dc1"
  type              = "ipv4"
  auto_delete       = false
  labels            = local.labels
  delete_protection = var.environment == "prod-hetz"
}

resource "hcloud_server" "main" {
  name              = "dreamseed-${var.environment}"
  server_type       = var.server_type
  image             = "ubuntu-24.04"
  location          = var.location
  labels            = local.labels
  ssh_keys          = local.use_existing_key ? [data.hcloud_ssh_key.default[0].id] : [hcloud_ssh_key.ci_key[0].id]
  firewall_ids      = [hcloud_firewall.web.id]
  delete_protection = var.environment == "prod-hetz"

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
    ipv4         = local.use_existing_ip ? data.hcloud_primary_ip.main[0].id : (local.create_primary_ip ? hcloud_primary_ip.main[0].id : null)
  }

  user_data = <<EOF
#!/bin/bash
set -e
hostnamectl set-hostname dreamseed-${var.environment}
if ! id ubuntu &>/dev/null; then
  useradd -m -s /bin/bash -G sudo ubuntu
  echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/99-ubuntu
fi
%{if length(var.additional_ssh_keys) > 0~}
mkdir -p /home/ubuntu/.ssh
%{for key in var.additional_ssh_keys~}
echo '${base64encode(key)}' | base64 -d >> /home/ubuntu/.ssh/authorized_keys
%{endfor~}
chmod 600 /home/ubuntu/.ssh/authorized_keys
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
%{endif~}
apt-get update -qq
EOF
}

check "workspace_valid_for_hetzner" {
  assert {
    condition     = contains(["dev-hetz", "test", "prod-hetz"], terraform.workspace)
    error_message = "Hetzner provider can only be used with workspace dev-hetz, test, or prod-hetz (got: ${terraform.workspace})"
  }
}

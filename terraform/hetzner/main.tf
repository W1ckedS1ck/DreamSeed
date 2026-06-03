locals {
  use_dynamic_ip   = var.primary_ip_name == ""
  use_existing_key = var.ssh_key_name != ""
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
  labels       = local.labels
  ssh_keys     = local.use_existing_key ? [data.hcloud_ssh_key.default[0].id] : [hcloud_ssh_key.ci_key[0].id]
  firewall_ids = [hcloud_firewall.web.id]

  public_net {
    ipv4_enabled = true
    ipv4         = local.use_dynamic_ip ? null : data.hcloud_primary_ip.main[0].id
  }

  user_data = <<EOF
#!/bin/bash
useradd -m -s /bin/bash -G sudo ubuntu
mkdir -p /home/ubuntu/.ssh
# Only write the intended public key, don't copy platform-injected keys from root
echo ${var.ssh_public_key} > /home/ubuntu/.ssh/authorized_keys
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
chmod 600 /home/ubuntu/.ssh/authorized_keys
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu
echo 'PermitRootLogin no' > /etc/ssh/sshd_config.d/disable-root.conf
systemctl restart ssh
apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
EOF
}

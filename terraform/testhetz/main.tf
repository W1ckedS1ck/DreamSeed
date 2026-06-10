locals {
  use_existing_key = var.ssh_key_name != ""
}

data "hcloud_ssh_key" "deploy" {
  count = local.use_existing_key ? 1 : 0
  name  = var.ssh_key_name
}

resource "hcloud_ssh_key" "auto" {
  count      = local.use_existing_key ? 0 : 1
  name       = "testhetz-${var.server_type}"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "main" {
  name        = "testhetz-${var.server_type}"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location

  ssh_keys = local.use_existing_key
    ? [data.hcloud_ssh_key.deploy[0].id]
    : [hcloud_ssh_key.auto[0].id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  user_data = templatefile("${path.module}/cloud-init.sh.tftpl", {
    server_type = var.server_type
  })
}

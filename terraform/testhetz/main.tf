data "hcloud_ssh_key" "deploy" {
  name = var.ssh_key_name
}

resource "hcloud_server" "main" {
  name        = "testhetz-${var.server_type}"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.deploy.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  user_data = templatefile("${path.module}/cloud-init.sh.tftpl", {
    server_type = var.server_type
  })
}

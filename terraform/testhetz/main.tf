resource "hcloud_ssh_key" "deploy" {
  name       = "testhetz-${var.server_type}"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "main" {
  name        = "testhetz-${var.server_type}"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.deploy.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  user_data = templatefile("${path.module}/cloud-init.sh.tftpl", {
    server_type = var.server_type
  })
}

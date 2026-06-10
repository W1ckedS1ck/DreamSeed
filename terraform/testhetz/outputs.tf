output "server_ipv4" {
  description = "Public IP address"
  value       = hcloud_server.main.ipv4_address
}

output "server_type" {
  description = "Hetzner server type"
  value       = hcloud_server.main.server_type
}

output "cpu_type" {
  description = "CPU type reported by cloud-init"
  value       = var.server_type
}

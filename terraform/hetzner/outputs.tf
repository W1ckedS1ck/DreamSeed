output "server_ipv4" {
  description = "Public IP address of the Hetzner instance"
  value       = hcloud_server.main.ipv4_address
}

output "server_id" {
  description = "ID of the Hetzner server (for API operations)"
  value       = hcloud_server.main.id
}

output "primary_ip_id" {
  description = "ID of the Primary IP (for API operations)"
  value       = local.use_existing_ip ? data.hcloud_primary_ip.main[0].id : (local.create_primary_ip ? hcloud_primary_ip.main[0].id : null)
}

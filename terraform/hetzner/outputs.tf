output "server_ipv4" {
  description = "Public IP address of the Hetzner instance"
  value       = hcloud_server.main.ipv4_address
}

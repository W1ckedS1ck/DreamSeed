output "server_ipv4" {
  description = "Public IP address of the instance"
  value       = var.elastic_ip_allocation_id != "" ? data.aws_eip.reserved[0].public_ip : aws_instance.web.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.web.id
}

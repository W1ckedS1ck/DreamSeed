output "instance_id" {
  value       = cloudru_evolution_compute_vm.main.id
  description = "Instance ID"
}

output "instance_name" {
  value       = cloudru_evolution_compute_vm.main.name
  description = "Instance name"
}

output "instance_status" {
  value       = cloudru_evolution_compute_vm.main.status
  description = "Instance status"
}

output "disk_id" {
  value       = cloudru_evolution_compute_disk.main.id
  description = "Boot disk ID"
}

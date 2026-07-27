output "folder_uid" {
  description = "DreamSeed folder UID in Grafana Cloud"
  value       = grafana_folder.dreamseed.uid
}

output "dashboard_uids" {
  description = "Map of dashboard names to UIDs"
  value = {
    for k, d in grafana_dashboard.this : k => d.uid
  }
}

output "dashboard_urls" {
  description = "Map of dashboard names to URLs"
  value = {
    for k, d in grafana_dashboard.this : k => d.url
  }
}

output "sm_check_ids" {
  description = "Map of synthetic monitoring check names to IDs"
  value = var.sm_enabled ? {
    http_main    = try(grafana_synthetic_monitoring_check.http_main[0].id, null)
    multi_main   = try(grafana_synthetic_monitoring_check.multi_main[0].id, null)
    http_grafana = try(grafana_synthetic_monitoring_check.http_grafana[0].id, null)
    ssl_main     = try(grafana_synthetic_monitoring_check.ssl_main[0].id, null)
  } : {}
}

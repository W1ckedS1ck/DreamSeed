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
  value = {
    http_main   = grafana_synthetic_monitoring_check.http_main[0].id
    http_grafana = grafana_synthetic_monitoring_check.http_grafana[0].id
    ssl         = grafana_synthetic_monitoring_check.ssl[0].id
    ping        = grafana_synthetic_monitoring_check.ping[0].id
    dns         = grafana_synthetic_monitoring_check.dns[0].id
  }
}

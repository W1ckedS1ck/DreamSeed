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
  description = "Map of synthetic monitoring check IDs keyed by type/domain"
  value = var.sm_enabled ? merge(
    { for i, c in grafana_synthetic_monitoring_check.http_main : "http_main/${var.domains[i]}" => c.id },
    { for i, c in grafana_synthetic_monitoring_check.multi_main : "multi_main/${var.domains[i]}" => c.id },
    { for i, c in grafana_synthetic_monitoring_check.http_grafana : "http_grafana/${var.domains[i]}" => c.id },
    { for i, c in grafana_synthetic_monitoring_check.ssl_main : "ssl_main/${var.domains[i]}" => c.id }
  ) : {}
}

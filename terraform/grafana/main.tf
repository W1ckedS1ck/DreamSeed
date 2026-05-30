data "http" "node_exporter_dashboard" {
  url = "https://grafana.com/api/dashboards/1860/revisions/latest/download"
}

data "http" "mysql_dashboard" {
  url = "https://grafana.com/api/dashboards/7362/revisions/latest/download"
}

data "http" "nginx_dashboard" {
  url = "https://grafana.com/api/dashboards/17452/revisions/latest/download"
}

data "http" "victoria_metrics_dashboard" {
  url = "https://grafana.com/api/dashboards/10229/revisions/latest/download"
}

locals {
  node_exporter_config = jsonencode(merge(
    jsondecode(data.http.node_exporter_dashboard.response_body),
    { id = null }
  ))
  mysql_config = jsonencode(merge(
    jsondecode(data.http.mysql_dashboard.response_body),
    { id = null }
  ))
  nginx_config = jsonencode(merge(
    jsondecode(data.http.nginx_dashboard.response_body),
    { id = null }
  ))
  victoria_metrics_config = jsonencode(merge(
    jsondecode(data.http.victoria_metrics_dashboard.response_body),
    { id = null }
  ))
}

resource "grafana_dashboard" "node_exporter" {
  config_json = local.node_exporter_config
}

resource "grafana_dashboard" "mysql" {
  config_json = local.mysql_config
}

resource "grafana_dashboard" "nginx" {
  config_json = local.nginx_config
}

resource "grafana_dashboard" "victoria_metrics" {
  config_json = local.victoria_metrics_config
}

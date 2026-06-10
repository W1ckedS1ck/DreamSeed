# Grafana Cloud Synthetic Monitoring — fit within free tier (10k checks/mo).
# HTTP from 3 US probes every 13 min ≈ 9,969 checks/mo.
# SSL skipped — Cloudflare handles edge termination.

data "grafana_synthetic_monitoring_probes" "main" {
  provider = grafana.sm
}

locals {
  sm_probes = ["NorthCalifornia", "Ohio", "NorthVirginia"]
}

# --- HTTP check — main site ---
resource "grafana_synthetic_monitoring_check" "http_main" {
  count    = var.sm_enabled ? 1 : 0
  provider = grafana.sm
  job      = "HTTP — ${var.domain}"
  target   = "https://${var.domain}/"
  enabled  = true
  frequency = 780000
  timeout   = 10000

  settings {
    http {
      method             = "GET"
      fail_if_not_ssl    = true
      valid_status_codes = [200, 301, 302]
      tls_config {
        server_name = var.domain
      }
    }
  }

  probes = [for p in local.sm_probes : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# Grafana Cloud Synthetic Monitoring — fit within free tier (100k API checks/mo).
# Main site: 3 US probes every 13 min ≈ 9,969 checks/mo.
# Grafana endpoint: 4 probes (3 US + 1 EU) every 15 min ≈ 11,520 checks/mo.
# Total ≈ 21,489 checks/mo — well within 100k free tier.
# SSL skipped — Cloudflare handles edge termination.

data "grafana_synthetic_monitoring_probes" "main" {
  provider = grafana.sm
}

locals {
  sm_probes_us  = ["NorthCalifornia", "Ohio", "NorthVirginia"]
  sm_probes_all = ["NorthCalifornia", "Ohio", "NorthVirginia", "Frankfurt"]
}

# --- HTTP check — main site ---
resource "grafana_synthetic_monitoring_check" "http_main" {
  count     = var.sm_enabled ? 1 : 0
  provider  = grafana.sm
  job       = "HTTP — ${var.domain}"
  target    = "https://${var.domain}/"
  enabled   = true
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

  probes = [for p in local.sm_probes_us : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- MultiHTTP check — user flow (homepage → manager) ---
resource "grafana_synthetic_monitoring_check" "multi_main" {
  count     = var.sm_enabled ? 1 : 0
  provider  = grafana.sm
  job       = "MultiHTTP — ${var.domain}"
  target    = "https://${var.domain}/"
  enabled   = true
  frequency = 1800000
  timeout   = 30000

  settings {
    multihttp {
      entries {
        request {
          method = "GET"
          url    = "https://${var.domain}/"
        }
        assertions {
          type      = "TEXT"
          subject   = "HTTP_STATUS_CODE"
          condition = "EQUALS"
          value     = "200"
        }
        assertions {
          type      = "TEXT"
          subject   = "RESPONSE_BODY"
          condition = "CONTAINS"
          value     = "DreamSeed"
        }
      }
      entries {
        request {
          method = "GET"
          url    = "https://${var.domain}/manager/"
        }
        assertions {
          type      = "TEXT"
          subject   = "HTTP_STATUS_CODE"
          condition = "EQUALS"
          value     = "200"
        }
      }
    }
  }

  probes = [data.grafana_synthetic_monitoring_probes.main.probes["Ohio"]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- HTTP check — Grafana endpoint (multi-region incl. Europe) ---
resource "grafana_synthetic_monitoring_check" "http_grafana" {
  count     = var.sm_enabled ? 1 : 0
  provider  = grafana.sm
  job       = "HTTP — Grafana — ${var.domain}"
  target    = "https://${var.domain}/grafana"
  enabled   = true
  frequency = 900000
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

  probes = [for p in local.sm_probes_all : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

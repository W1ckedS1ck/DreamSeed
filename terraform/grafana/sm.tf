# Grafana Cloud Synthetic Monitoring — fit within free tier (100k API checks/mo).
# Budget: main site (3 America probes×15min ≈ 8.5k) + multi (2 probes×30min ≈ 2.9k)
#         + grafana (2 probes×30min ≈ 2.9k) + SSL (1 probe×1h ≈ 720)
#         ≈ 15k checks/mo — well within 100k free tier.

data "grafana_synthetic_monitoring_probes" "main" {
  provider = grafana.sm
}

locals {
  sm_probes_america = ["NorthCalifornia", "Ohio", "Montreal"]
}

# --- HTTP check — main site (US West + Central + Canada, every 15 min) ---
resource "grafana_synthetic_monitoring_check" "http_main" {
  count     = var.sm_enabled ? 1 : 0
  provider  = grafana.sm
  job       = "HTTP — ${var.domain}"
  target    = "https://${var.domain}/"
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

  probes = [for p in local.sm_probes_america : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- MultiHTTP check — user flow (homepage → manager, 2 US probes) ---
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

  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["NorthCalifornia"],
    data.grafana_synthetic_monitoring_probes.main.probes["Ohio"],
  ]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- HTTP check — Grafana endpoint (2 US probes, every 30 min) ---
resource "grafana_synthetic_monitoring_check" "http_grafana" {
  count     = var.sm_enabled ? 1 : 0
  provider  = grafana.sm
  job       = "HTTP — Grafana — ${var.domain}"
  target    = "https://${var.domain}/grafana"
  enabled   = true
  frequency = 1800000
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

  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["NorthCalifornia"],
    data.grafana_synthetic_monitoring_probes.main.probes["Ohio"],
  ]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- SSL check — Cloudflare cert validation (1 probe, every hour — max SM interval) ---
resource "grafana_synthetic_monitoring_check" "ssl_main" {
  count     = var.sm_enabled ? 1 : 0
  provider  = grafana.sm
  job       = "SSL — ${var.domain}"
  target    = "${var.domain}:443"
  enabled   = true
  frequency = 3600000
  timeout   = 10000

  settings {
    tcp {
      tls = true
      tls_config {
        server_name = var.domain
      }
    }
  }

  probes = [data.grafana_synthetic_monitoring_probes.main.probes["Ohio"]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }

  lifecycle {
    prevent_destroy = true
  }
}

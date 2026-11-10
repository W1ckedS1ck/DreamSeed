# Grafana Cloud Synthetic Monitoring — fit within free tier (100k API checks/mo).
# Budget per domain: main site (5 global probes×10min ≈ 21.6k) + multi (2 probes×30min ≈ 2.9k)
#         + grafana (2 probes×30min ≈ 2.9k) + SSL (3 global probes×1h ≈ 2.2k)
#         ≈ 29.6k checks/mo. One domain ≈ 30% of the free tier; both dev domains
#         ≈ 59.2k, still under the 100k limit.

data "grafana_synthetic_monitoring_probes" "main" {
  provider = grafana.sm
}

locals {
  # Probe names are map keys into data.grafana_synthetic_monitoring_probes.main.
  # A Grafana-side rename would break `terraform plan` with an "invalid map key"
  # error — loud, not silent. Centralized here so a rename is a one-line fix.
  # The exact probe set is a budget decision (free tier, ~29.6k checks/mo).
  # "global" = North America + Europe + Asia — real multi-continent coverage.
  sm_probes_global  = ["NorthCalifornia", "Ohio", "Montreal", "London", "Singapore"]
  sm_probes_multi   = ["NorthCalifornia", "Ohio"]
  sm_probes_grafana = ["NorthCalifornia", "Ohio"]
  sm_probes_ssl     = ["Ohio", "London", "Singapore"]
}

# --- HTTP check — main site (US West + Central + Canada + Europe + Asia, every 10 min) ---
resource "grafana_synthetic_monitoring_check" "http_main" {
  count     = var.sm_enabled ? length(var.domains) : 0
  provider  = grafana.sm
  job       = "HTTP — ${var.domains[count.index]}"
  target    = "https://${var.domains[count.index]}/"
  enabled   = true
  frequency = 600000
  timeout   = 10000

  settings {
    http {
      method             = "GET"
      fail_if_not_ssl    = true
      valid_status_codes = [200, 301, 302]
      tls_config {
        server_name = var.domains[count.index]
      }
    }
  }

  probes = [for p in local.sm_probes_global : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domains[count.index]
  }


}

# --- MultiHTTP check — user flow (homepage → manager, 2 US probes) ---
resource "grafana_synthetic_monitoring_check" "multi_main" {
  count     = var.sm_enabled ? length(var.domains) : 0
  provider  = grafana.sm
  job       = "MultiHTTP — ${var.domains[count.index]}"
  target    = "https://${var.domains[count.index]}/"
  enabled   = true
  frequency = 1800000
  timeout   = 30000

  settings {
    multihttp {
      entries {
        request {
          method = "GET"
          url    = "https://${var.domains[count.index]}/"
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
          url    = "https://${var.domains[count.index]}/manager/"
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

  probes = [for p in local.sm_probes_multi : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domains[count.index]
  }


}

# --- HTTP check — Grafana endpoint (2 US probes, every 30 min) ---
resource "grafana_synthetic_monitoring_check" "http_grafana" {
  count     = var.sm_enabled ? length(var.domains) : 0
  provider  = grafana.sm
  job       = "HTTP — Grafana — ${var.domains[count.index]}"
  target    = "https://${var.domains[count.index]}/grafana"
  enabled   = true
  frequency = 1800000
  timeout   = 10000

  settings {
    http {
      method             = "GET"
      fail_if_not_ssl    = true
      valid_status_codes = [200, 301, 302]
      tls_config {
        server_name = var.domains[count.index]
      }
    }
  }

  probes = [for p in local.sm_probes_grafana : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domains[count.index]
  }


}

# --- SSL check — Cloudflare cert validation (3 probes, hourly — max SM interval) ---
resource "grafana_synthetic_monitoring_check" "ssl_main" {
  count     = var.sm_enabled ? length(var.domains) : 0
  provider  = grafana.sm
  job       = "SSL — ${var.domains[count.index]}"
  target    = "${var.domains[count.index]}:443"
  enabled   = true
  frequency = 3600000
  timeout   = 10000

  settings {
    tcp {
      tls = true
      tls_config {
        server_name = var.domains[count.index]
      }
    }
  }

  probes = [for p in local.sm_probes_ssl : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domains[count.index]
  }


}

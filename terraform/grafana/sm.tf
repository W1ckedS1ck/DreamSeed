# Grafana Cloud Synthetic Monitoring — enabled per-workspace via sm_enabled var
# Prerequisite: enable SM once manually in Grafana Cloud UI (Stack → SM → Enable).
# After that, SA token with SM scope is all that's needed.
# Probes: London, Frankfurt, NorthVirginia, Singapore

data "grafana_synthetic_monitoring_probes" "main" {
  provider = grafana.sm
}

# --- HTTP check — main site ---
resource "grafana_synthetic_monitoring_check" "http_main" {
  count    = var.sm_enabled ? 1 : 0
  provider = grafana.sm
  job      = "HTTP — ${var.domain}"
  target   = "https://${var.domain}/"
  enabled  = true
  frequency = 120000
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

  probes = [for p in local.probes_http : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- HTTP check — Grafana endpoint ---
resource "grafana_synthetic_monitoring_check" "http_grafana" {
  count    = var.sm_enabled ? 1 : 0
  provider = grafana.sm
  job      = "HTTP — Grafana (${var.domain})"
  target   = "https://${var.domain}/grafana/"
  enabled  = true
  frequency = 120000
  timeout   = 10000

  settings {
    http {
      method             = "GET"
      fail_if_not_ssl    = true
      valid_status_codes = [200, 301, 302]
    }
  }

  probes = [for p in local.probes_http : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- SSL check ---
resource "grafana_synthetic_monitoring_check" "ssl" {
  count    = var.sm_enabled ? 1 : 0
  provider = grafana.sm
  job      = "SSL — ${var.domain}"
  target   = "https://${var.domain}/"
  enabled  = true
  frequency = 300000
  timeout   = 15000

  settings {
    http {
      method          = "GET"
      fail_if_ssl     = false
      fail_if_not_ssl = true
      valid_status_codes = [200, 301, 302]
      tls_config {
        server_name = var.domain
      }
    }
  }

  probes = [for p in local.probes_ssl : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- Ping check — latency ---
resource "grafana_synthetic_monitoring_check" "ping" {
  count    = var.sm_enabled ? 1 : 0
  provider = grafana.sm
  job      = "Ping — ${var.domain}"
  target   = var.domain
  enabled  = true
  frequency = 60000
  timeout   = 10000

  settings {
    ping {
      ip_version = "Any"
    }
  }

  probes = [for p in local.probes_http : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- DNS check ---
resource "grafana_synthetic_monitoring_check" "dns" {
  count    = var.sm_enabled ? 1 : 0
  provider = grafana.sm
  job      = "DNS — ${var.domain}"
  target   = var.domain
  enabled  = true
  frequency = 300000
  timeout   = 10000

  settings {
    dns {
      server      = "8.8.8.8"
      record_type = "A"
      protocol    = "UDP"
      ip_version  = "Any"
      valid_r_codes = ["NOERROR"]
    }
  }

  probes = [for p in local.probes_ssl : data.grafana_synthetic_monitoring_probes.main.probes[p]]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

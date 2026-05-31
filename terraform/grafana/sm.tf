# Grafana Cloud Synthetic Monitoring — enabled per-workspace via sm_enabled var
# Requires: SM access token with Synthetic Monitoring scope in the workspace
# Probes used: London, Frankfurt, New York City, Singapore (4 global regions)

resource "grafana_synthetic_monitoring_installation" "this" {
  count                 = var.sm_enabled ? 1 : 0
  stack_id              = var.sm_stack_id
  metrics_publisher_key = var.sm_metrics_publisher_key
}

data "grafana_synthetic_monitoring_probes" "main" {
  depends_on = [grafana_synthetic_monitoring_installation.this]
}

# --- HTTP check — main site ---
resource "grafana_synthetic_monitoring_check" "http_main" {
  count    = var.sm_enabled ? 1 : 0
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

  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["London"],
    data.grafana_synthetic_monitoring_probes.main.probes["Frankfurt"],
    data.grafana_synthetic_monitoring_probes.main.probes["New York City"],
    data.grafana_synthetic_monitoring_probes.main.probes["Singapore"],
  ]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- HTTP check — Grafana endpoint ---
resource "grafana_synthetic_monitoring_check" "http_grafana" {
  count    = var.sm_enabled ? 1 : 0
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

  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["London"],
    data.grafana_synthetic_monitoring_probes.main.probes["Frankfurt"],
    data.grafana_synthetic_monitoring_probes.main.probes["New York City"],
    data.grafana_synthetic_monitoring_probes.main.probes["Singapore"],
  ]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- SSL check ---
resource "grafana_synthetic_monitoring_check" "ssl" {
  count    = var.sm_enabled ? 1 : 0
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

  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["London"],
    data.grafana_synthetic_monitoring_probes.main.probes["Frankfurt"],
    data.grafana_synthetic_monitoring_probes.main.probes["New York City"],
  ]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- Ping check — latency ---
resource "grafana_synthetic_monitoring_check" "ping" {
  count    = var.sm_enabled ? 1 : 0
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

  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["London"],
    data.grafana_synthetic_monitoring_probes.main.probes["Frankfurt"],
    data.grafana_synthetic_monitoring_probes.main.probes["New York City"],
    data.grafana_synthetic_monitoring_probes.main.probes["Singapore"],
  ]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

# --- DNS check ---
resource "grafana_synthetic_monitoring_check" "dns" {
  count    = var.sm_enabled ? 1 : 0
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

  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["London"],
    data.grafana_synthetic_monitoring_probes.main.probes["Frankfurt"],
    data.grafana_synthetic_monitoring_probes.main.probes["New York City"],
  ]

  labels = {
    env    = terraform.workspace
    domain = var.domain
  }
}

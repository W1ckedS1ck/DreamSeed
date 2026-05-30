terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 2.0"
    }
  }
  cloud {
    organization = "DreamSeed"
    workspaces {
      name = "grafana-cloud"
    }
  }
}

provider "grafana" {
  url  = var.grafana_cloud_url
  auth = "admin:${var.grafana_cloud_token}"
}

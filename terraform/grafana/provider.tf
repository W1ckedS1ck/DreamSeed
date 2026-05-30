terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 2.0"
    }
  }
  backend "remote" {
    organization = "DreamSeed"
    workspaces {
      prefix = "dreamseed-grafana-cloud-"
    }
  }
}

provider "grafana" {
  url  = var.grafana_cloud_url
  auth = var.grafana_cloud_token
}

terraform {
  required_version = ">= 1.5"
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
  auth = ":${var.grafana_cloud_token}"
}

provider "grafana" {
  alias           = "sm"
  url             = var.grafana_cloud_url
  auth            = var.grafana_cloud_token
  sm_access_token = var.sm_access_token
  sm_url          = var.sm_url
}

terraform {
  required_version = ">= 1.5"

  backend "local" {
    path = "testhetz.tfstate"
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.63.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

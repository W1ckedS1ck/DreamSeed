terraform {
  required_version = ">= 1.5"

  backend "remote" {
    organization = "DreamSeed"
    workspaces {
      prefix = "dreamseed-"
    }
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

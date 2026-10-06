terraform {
  required_version = ">= 1.5, < 2.0"

  backend "remote" {
    organization = "DreamSeed"
    workspaces {
      prefix = "dreamseed-"
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

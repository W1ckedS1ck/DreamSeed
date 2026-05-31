terraform {
  required_version = ">= 1.1"

  backend "remote" {
    organization = "DreamSeed"
    workspaces {
      prefix = "dreamseed-"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = local.environment_tag
      Service     = local.service_tag
    }
  }
}

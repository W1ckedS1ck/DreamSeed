terraform {
  required_version = ">= 1.1"

  backend "remote" {
    organization = "Dreamseed"
    workspaces {
      prefix = "dreamseed-"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477", "839968031152"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] # 24.04 LTS
    #   values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]   # 26.04 LTS
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
}

variable "elastic_ip_allocation_id" {
  description = "Allocation ID of an existing Elastic IP to associate. Leave empty to skip EIP association."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Deployment environment (prod, dev-aws, etc.) — used in resource names to avoid conflicts"
  type        = string
  default     = "prod"
}

variable "domain" {
  description = "Domain name for the deployment (e.g., dreamseed.online, test.dreamseed.online)"
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS management"
  type        = string
  default     = ""
}

locals {
  environment_tag = var.environment == "prod" ? "Prod" : "Dev"
  service_tag     = "DreamSeed"
}

resource "aws_key_pair" "deploy" {
  key_name   = "dreamseed-key-${var.environment}"
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = {
    Name        = "dreamseed-key-${var.environment}"
    Environment = local.environment_tag
    Service     = local.service_tag
  }
}

resource "aws_security_group" "web" {
  name        = "dreamseed-sg-${var.environment}"
  description = "Security group for DreamSeed web server (${var.environment})"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-ingress-sgr
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-ingress-sgr
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-ingress-sgr
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }

  tags = {
    Name        = "dreamseed-sg-${var.environment}"
    Environment = local.environment_tag
    Service     = local.service_tag
  }
}

resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.deploy.key_name
  security_groups             = [aws_security_group.web.name]
  associate_public_ip_address = false

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
    tags = {
      Name        = "dreamseed-${var.environment}-root"
      Environment = local.environment_tag
      Service     = local.service_tag
    }
  }

  user_data = <<-EOF
  #!/bin/bash
  hostnamectl set-hostname dreamseed-${var.environment}
  sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  systemctl restart sshd
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  EOF

  metadata_options {
    http_tokens = "required"
  }

  ebs_optimized = true

  tags = {
    Name        = "dreamseed-${var.environment}"
    Environment = local.environment_tag
    Service     = local.service_tag
  }
}

resource "aws_eip" "dynamic" {
  count  = var.domain != "" && var.elastic_ip_allocation_id == "" ? 1 : 0
  domain = "vpc"
  tags = {
    Name        = "dreamseed-dynamic-${var.environment}"
    Environment = local.environment_tag
    Service     = local.service_tag
  }
}

data "aws_eip" "reserved" {
  count = var.elastic_ip_allocation_id != "" ? 1 : 0
  id    = var.elastic_ip_allocation_id
}

resource "aws_eip_association" "web" {
  count         = var.elastic_ip_allocation_id != "" || var.domain != "" ? 1 : 0
  allocation_id = var.domain != "" ? aws_eip.dynamic[0].id : data.aws_eip.reserved[0].id
  instance_id   = aws_instance.web.id
}

resource "cloudflare_record" "dynamic" {
  count   = var.domain != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  value   = var.domain != "" ? aws_eip.dynamic[0].public_ip : data.aws_eip.reserved[0].public_ip
  type    = "A"
  proxied = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for DNS management"
  type        = string
  default     = ""
}

output "server_ipv4" {
  description = "Public IP address of the instance"
  value       = var.domain != "" ? aws_eip.dynamic[0].public_ip : (var.elastic_ip_allocation_id != "" ? data.aws_eip.reserved[0].public_ip : aws_instance.web.public_ip)
}

output "instance_id" {
  description = "Instance ID"
  value       = aws_instance.web.id
}

# Cloudflare edge ranges — web traffic MUST only come from CF (origin hidden
# behind proxy). SSH (22) stays open to the world for Ansible. Fetched live from
# cloudflare.com at plan time, so the firewall always tracks current ranges.
data "http" "cf_ips_v4" {
  url = "https://www.cloudflare.com/ips-v4"
}

data "http" "cf_ips_v6" {
  url = "https://www.cloudflare.com/ips-v6"
}

locals {
  environment_tag = var.environment == "prod" ? "Prod" : "Dev"
  service_tag     = "DreamSeed"
  cf_ipv4         = compact(split("\n", trimspace(data.http.cf_ips_v4.response_body)))
  cf_ipv6         = compact(split("\n", trimspace(data.http.cf_ips_v6.response_body)))
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] # 24.04 LTS
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "deploy" {
  key_name   = "dreamseed-key-${var.environment}"
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = {
    Name = "dreamseed-key-${var.environment}"
  }

  lifecycle {
    ignore_changes = [public_key]
  }
}

resource "aws_security_group" "web" {
  # checkov:skip=CKV_AWS_24:SSH from anywhere required for Ansible provisioning; HTTP/HTTPS restricted to Cloudflare ranges
  name        = "dreamseed-sg-${var.environment}"
  description = "Security group for DreamSeed web server (${var.environment})"

  ingress {
    description      = "SSH"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-ingress-sgr
    ipv6_cidr_blocks = ["::/0"]      #tfsec:ignore:aws-ec2-no-public-ingress-sgr
  }

  ingress {
    description      = "HTTP (Cloudflare only)"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = local.cf_ipv4
    ipv6_cidr_blocks = local.cf_ipv6
  }

  ingress {
    description      = "HTTPS (Cloudflare only)"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = local.cf_ipv4
    ipv6_cidr_blocks = local.cf_ipv6
  }

  # NOTE: Egress is intentionally restricted to known ports.
  # Ports 80/443 cover apt, rclone, certbot, vmagent, curl, git+https.
  # If a new service needs a different port (e.g. SSH:22, git:9418) —
  # add it here explicitly. Do NOT open 0.0.0.0/0 all-ports.
  egress {
    description      = "HTTP (apt, certbot)"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
    ipv6_cidr_blocks = ["::/0"]      #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }

  egress {
    description      = "HTTPS (apt, certbot, rclone, vmagent, git)"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
    ipv6_cidr_blocks = ["::/0"]      #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }

  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }

  egress {
    description = "NTP"
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }

  egress {
    description = "SMTP (mail.privateemail.com)"
    from_port   = 587
    to_port     = 587
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }

  tags = {
    Name = "dreamseed-sg-${var.environment}"
  }
}

resource "aws_instance" "web" {
  # checkov:skip=CKV_AWS_126:Detailed monitoring costs extra — not needed for t3.small with VictoriaMetrics scraping from inside
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.deploy.key_name
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = !var.disable_auto_public_ip

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
    tags = {
      Name = "dreamseed-${var.environment}-root"
    }
  }

  user_data = templatefile("${path.module}/cloud-init.tftpl", {
    environment         = var.environment
    additional_ssh_keys = var.additional_ssh_keys
  })

  metadata_options {
    http_tokens = "required"
  }

  ebs_optimized           = true
  disable_api_termination = var.environment == "prod"

  # prevent_destroy intentionally omitted — Terraform 1.11+ rejects variables in lifecycle.
  # Prod protection uses disable_api_termination above.

  lifecycle {
    # user_data: cloud-init runs once at first boot. Changing template has no effect.
    # Without this, any change to cloud-init.tftpl triggers an EC2 stop/start.
    #
    # ami: data.aws_ami tracks "most_recent" Ubuntu 24.04 point-release. Without
    # this, a fresh Canonical AMI would silently plan an instance REPLACE on the
    # next deploy (downtime + new ephemeral state). Pin at creation; upgrade
    # deliberately via taint/rebuild.
    ignore_changes = [
      user_data,
      ami,
    ]
  }

  tags = {
    Name = "dreamseed-${var.environment}"
  }
}

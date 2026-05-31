locals {
  environment_tag = var.environment == "prod" ? "Prod" : "Dev"
  service_tag     = "DreamSeed"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

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

resource "aws_key_pair" "deploy" {
  key_name   = "dreamseed-key-${var.environment}"
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = {
    Name = "dreamseed-key-${var.environment}"
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
    Name = "dreamseed-sg-${var.environment}"
  }
}

resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.deploy.key_name
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = var.elastic_ip_allocation_id == ""

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
    tags = {
      Name = "dreamseed-${var.environment}-root"
    }
  }

  user_data = <<EOF
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
    Name = "dreamseed-${var.environment}"
  }
}

data "aws_eip" "reserved" {
  count = var.elastic_ip_allocation_id != "" ? 1 : 0
  id    = var.elastic_ip_allocation_id
}

resource "aws_eip_association" "web" {
  count         = var.elastic_ip_allocation_id != "" ? 1 : 0
  allocation_id = data.aws_eip.reserved[0].id
  instance_id   = aws_instance.web.id
}

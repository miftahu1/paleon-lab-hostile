# ==============================================================================
# PALEON TEST SITE 7 - Main Infrastructure
# ==============================================================================
# Isolated hostile test target. All resources use the "paleon-site7" prefix.
# No IAM role is attached to the instance (intentionally minimal privileges).
# No shared resources with other Paleon test sites.
#
# Topology:
#   EC2 (Ubuntu 24.04 LTS, default VPC)
#     - Public ports: 22 (admin CIDR), 53 TCP/UDP, 80, 443
#     - Elastic IP allocated first, then associated (no dependency cycle)
#     - User data receives the EIP via templatefile (no IMDS / no external IP lookup)
#   Route 53 (parent zone paleon-lab-hostile.com)
#     - A: apex, offscope, malformed-http, malformed-tls, ns1
#     - NS: rebind-test.paleon-lab-hostile.com -> ns1.paleon-lab-hostile.com
# ==============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "lab"
      ManagedBy   = "terraform"
      Site        = "paleon-site7"
      Purpose     = "hostile-test-target"
    }
  }
}

# ------------------------------------------------------------------------------
# Data Sources
# ------------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ------------------------------------------------------------------------------
# Security Group
# ------------------------------------------------------------------------------

resource "aws_security_group" "paleon-site7-sg" {
  name        = "${var.project_name}-sg"
  description = "Site 7 hostile test target - no shared resources with other sites"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere (SNI routing)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from admin IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip]
  }

  ingress {
    description = "DNS TCP for rebinding tests"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "DNS UDP for rebinding tests"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Default AWS egress (all outbound) is retained so bootstrap can apt/git.
  # Application processes are later restricted on-host with iptables uid rules.
  tags = {
    Name = "${var.project_name}-sg"
  }
}

# ------------------------------------------------------------------------------
# Elastic IP (allocated independently of the instance — no cycle)
# ------------------------------------------------------------------------------
# Cycle-safe lifecycle:
#   1. Allocate EIP (public_ip known immediately)
#   2. Create instance (user_data injects that public_ip)
#   3. Associate EIP to instance
# Instance user_data must NOT reference the association, and the EIP resource
# must NOT set instance = aws_instance.id.

resource "aws_eip" "paleon-site7-eip" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}

# ------------------------------------------------------------------------------
# EC2 Instance
# ------------------------------------------------------------------------------

resource "aws_instance" "paleon-site7" {
  ami                    = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_2404.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.paleon-site7-sg.id]

  # No IAM instance profile — intentionally minimal permissions.

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    domain_name = var.hostname
    public_ip   = aws_eip.paleon-site7-eip.public_ip
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 required; application code must not call IMDS
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-instance"
  }
}

resource "aws_eip_association" "paleon-site7-eip" {
  instance_id   = aws_instance.paleon-site7.id
  allocation_id = aws_eip.paleon-site7-eip.id
}

# ------------------------------------------------------------------------------
# Route 53 DNS Records
# ------------------------------------------------------------------------------

resource "aws_route53_record" "paleon-site7-primary" {
  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.paleon-site7-eip.public_ip]

  depends_on = [aws_eip_association.paleon-site7-eip]
}

resource "aws_route53_record" "paleon-site7-offscope" {
  zone_id = var.route53_zone_id
  name    = var.offscope_hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.paleon-site7-eip.public_ip]

  depends_on = [aws_eip_association.paleon-site7-eip]
}

resource "aws_route53_record" "paleon-site7-malformed-http" {
  zone_id = var.route53_zone_id
  name    = "malformed-http.${var.hostname}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.paleon-site7-eip.public_ip]

  depends_on = [aws_eip_association.paleon-site7-eip]
}

resource "aws_route53_record" "paleon-site7-malformed-tls" {
  zone_id = var.route53_zone_id
  name    = "malformed-tls.${var.hostname}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.paleon-site7-eip.public_ip]

  depends_on = [aws_eip_association.paleon-site7-eip]
}

# Glue A record: ns1 hostname resolves to the Site 7 EIP
resource "aws_route53_record" "paleon-site7-ns1" {
  zone_id = var.route53_zone_id
  name    = "ns1.${var.hostname}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.paleon-site7-eip.public_ip]

  depends_on = [aws_eip_association.paleon-site7-eip]
}

# NS delegation: rebind-test child zone is served by the instance DNS daemon
resource "aws_route53_record" "paleon-site7-rebind-ns" {
  zone_id = var.route53_zone_id
  name    = var.rebind_hostname
  type    = "NS"
  ttl     = 300
  records = ["ns1.${var.hostname}"]

  depends_on = [aws_eip_association.paleon-site7-eip]
}

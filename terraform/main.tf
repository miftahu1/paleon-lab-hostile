# ==============================================================================
# PALEON TEST SITE 7 - Main Infrastructure
# ==============================================================================
# Isolated hostile test target. All resources use the "paleon-site7" prefix.
# No IAM role is attached to the instance (intentionally minimal privileges).
# No shared resources with other Paleon test sites.
#
# Topology:
#   EC2 (Amazon Linux 2023)
#     - Security Group: HTTP/HTTPS from anywhere, SSH from admin_ip only
#     - Elastic IP for stable DNS
#     - User data bootstraps via scripts/user_data.sh
#   Route 53
#     - paleon-lab-hostile.com             -> EIP
#     - offscope.paleon-lab-hostile.com     -> EIP (same server)
#     - rebind-test.paleon-lab-hostile.com  -> public test IP (first lookup)
# ==============================================================================

# ------------------------------------------------------------------------------
# Provider
# ------------------------------------------------------------------------------

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

# Retrieve the VPC default for the selected region. Site 7 uses the default
# VPC to keep the lab simple; no custom networking is created.
data "aws_vpc" "default" {
  default = true
}

# ------------------------------------------------------------------------------
# Security Group
# ------------------------------------------------------------------------------

# Site 7 hostile test target - no shared resources with other sites.
resource "aws_security_group" "paleon-site7-sg" {
  name        = "${var.project_name}-sg"
  description = "Site 7 hostile test target - no shared resources with other sites"
  vpc_id      = data.aws_vpc.default.id

  # HTTP from anywhere -- required for the web-based test targets.
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS from anywhere -- required for TLS test scenarios.
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH from admin_ip only -- restrict to the operator's IP.
  # admin_ip must be provided; deployment fails without it.
  ingress {
    description = "SSH from admin IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip]
  }

  # No explicit outbound rules beyond AWS defaults.
  # Default egress allows all outbound traffic which is needed for
  # package updates and pulling dependencies during user_data bootstrap.
  # We document this as intentional: HTTPS outbound for updates only.
  tags = {
    Name = "${var.project_name}-sg"
  }
}

# ------------------------------------------------------------------------------
# EC2 Instance
# ------------------------------------------------------------------------------

# Main Site 7 test target instance. Deliberately has NO IAM instance profile
# or role attached -- the test target should have minimal AWS permissions.
resource "aws_instance" "paleon-site7" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.paleon-site7-sg.id]

  # No IAM instance profile -- intentionally minimal permissions.
  # iam_instance_profile = (not set)

  user_data = file("${path.module}/../scripts/user_data.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-instance"
  }
}

# ------------------------------------------------------------------------------
# Elastic IP
# ------------------------------------------------------------------------------

# Stable public IP for the Site 7 test target. Used for all DNS A records.
resource "aws_eip" "paleon-site7-eip" {
  instance = aws_instance.paleon-site7.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}

# ------------------------------------------------------------------------------
# Route 53 DNS Records
# ------------------------------------------------------------------------------

# Primary domain record -- points to the Elastic IP.
resource "aws_route53_record" "paleon-site7-primary" {
  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.paleon-site7-eip.public_ip]
}

# Off-scope subdomain -- same server handles both primary and off-scope
# hostnames. Useful for testing scope-based access controls.
resource "aws_route53_record" "paleon-site7-offscope" {
  zone_id = var.route53_zone_id
  name    = var.offscope_hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.paleon-site7-eip.public_ip]
}

# DNS rebinding test hostname. The initial A record points to a public test IP
# to simulate a rebinding scenario where the first lookup resolves to an
# external address before switching to the actual server.
resource "aws_route53_record" "paleon-site7-rebind" {
  zone_id = var.route53_zone_id
  name    = var.rebind_hostname
  type    = "A"
  ttl     = 60
  # Initial value is a well-known public test IP for DNS rebinding demos.
  # After bootstrap, the TTL is lowered and the record is updated to point
  # to the EIP via a separate process.
  records = ["93.184.216.34"]
}

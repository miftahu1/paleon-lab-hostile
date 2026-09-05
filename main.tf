# PALEON SITE 7 — TERRAFORM CONFIGURATION
# Hostile adversarial test target infrastructure

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "paleon-terraform-state"
    key    = "site7/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "Ubuntu 22.04 AMI ID"
  type        = string
  default     = "ami-0c02fb55956c7d316"  # Ubuntu 22.04 LTS in us-east-1
}

variable "ssh_key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the hostile test target"
  type        = string
  default     = "paleon-lab-hostile.com"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

# VPC and Networking
resource "aws_vpc" "site7_vpc" {
  cidr_block           = "10.7.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "paleon-site7-vpc"
  }
}

resource "aws_subnet" "site7_public" {
  vpc_id                  = aws_vpc.site7_vpc.id
  cidr_block              = "10.7.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "paleon-site7-public"
  }
}

resource "aws_internet_gateway" "site7_igw" {
  vpc_id = aws_vpc.site7_vpc.id

  tags = {
    Name = "paleon-site7-igw"
  }
}

resource "aws_route_table" "site7_public_rt" {
  vpc_id = aws_vpc.site7_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.site7_igw.id
  }

  tags = {
    Name = "paleon-site7-public-rt"
  }
}

resource "aws_route_table_association" "site7_public_rta" {
  subnet_id      = aws_subnet.site7_public.id
  route_table_id = aws_route_table.site7_public_rt.id
}

# Security Group
resource "aws_security_group" "site7_sg" {
  name        = "paleon-site7-sg"
  description = "Security group for Paleon Site 7 hostile test target"
  vpc_id      = aws_vpc.site7_vpc.id

  # SSH
  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # HTTP
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Flask app direct (for testing)
  ingress {
    description = "Flask app direct access"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Malformed server
  ingress {
    description = "Malformed server"
    from_port   = 5001
    to_port     = 5001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Rebinding DNS HTTP
  ingress {
    description = "Rebinding DNS HTTP"
    from_port   = 5002
    to_port     = 5002
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Rebinding DNS UDP
  ingress {
    description = "Rebinding DNS UDP"
    from_port   = 8053
    to_port     = 8053
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "paleon-site7-sg"
  }
}

# EC2 Instance
resource "aws_instance" "site7" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  subnet_id              = aws_subnet.site7_public.id
  vpc_security_group_ids = [aws_security_group.site7_sg.id]
  user_data              = templatefile("${path.module}/user_data.sh.tftpl", { domain_name = var.domain_name })

  iam_instance_profile = aws_iam_instance_profile.site7_profile.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "paleon-site7-hostile"
    Environment = "test"
    Sector      = "hostile-target"
  }

  depends_on = [
    aws_internet_gateway.site7_igw
  ]
}

# IAM Role for Instance
resource "aws_iam_role" "site7_role" {
  name = "paleon-site7-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_instance_profile" "site7_profile" {
  name = "paleon-site7-profile"
  role = aws_iam_role.site7_role.name
}

resource "aws_iam_role_policy" "site7_policy" {
  name = "paleon-site7-policy"
  role = aws_iam_role.site7_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

# Route53 Records (if hosted zone exists)
# data "aws_route53_zone" "paleon" {
#   name = "paleon-lab-hostile.com"
# }

# resource "aws_route53_record" "site7_a" {
#   zone_id = data.aws_route53_zone.paleon.zone_id
#   name    = "paleon-lab-hostile.com"
#   type    = "A"
#   ttl     = 300
#   records = [aws_instance.site7.public_ip]
# }

# resource "aws_route53_record" "site7_www" {
#   zone_id = data.aws_route53_zone.paleon.zone_id
#   name    = "www.paleon-lab-hostile.com"
#   type    = "A"
#   ttl     = 300
#   records = [aws_instance.site7.public_ip]
# }

# resource "aws_route53_record" "offscope_a" {
#   zone_id = data.aws_route53_zone.paleon.zone_id
#   name    = "offscope.paleon-lab-hostile.com"
#   type    = "A"
#   ttl     = 300
#   records = [aws_instance.site7.public_ip]
# }

# resource "aws_route53_record" "rebind_a" {
#   zone_id = data.aws_route53_zone.paleon.zone_id
#   name    = "rebind-test.paleon-lab-hostile.com"
#   type    = "A"
#   ttl     = 300
#   records = [aws_instance.site7.public_ip]
# }

# Outputs
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.site7.id
}

output "public_ip" {
  description = "Public IP address"
  value       = aws_instance.site7.public_ip
}

output "public_dns" {
  description = "Public DNS name"
  value       = aws_instance.site7.public_dns
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -i ${var.ssh_key_name}.pem ubuntu@${aws_instance.site7.public_ip}"
}
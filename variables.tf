# PALEON SITE 7 — TERRAFORM VARIABLES

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2", "eu-west-1"], var.aws_region)
    error_message = "Region must be us-east-1, us-west-2, or eu-west-1."
  }
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"

  validation {
    condition     = contains(["t3.medium", "t3.large", "t2.medium"], var.instance_type)
    error_message = "Instance type must be t3.medium, t3.large, or t2.medium."
  }
}

variable "ami_id" {
  description = "Ubuntu 22.04 AMI ID for the selected region"
  type        = string
  default     = "ami-0c02fb55956c7d316"
}

variable "ssh_key_name" {
  description = "Name of the SSH key pair for EC2 access"
  type        = string

  validation {
    condition     = length(var.ssh_key_name) > 0
    error_message = "SSH key name must be provided."
  }
}

variable "domain_name" {
  description = "Domain name for the hostile test target"
  type        = string
  default     = "paleon-lab-hostile.com"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access (restrict in production)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "environment" {
  description = "Environment name (test, staging, prod)"
  type        = string
  default     = "test"
}

variable "enable_https" {
  description = "Whether to enable HTTPS with certbot"
  type        = bool
  default     = true
}
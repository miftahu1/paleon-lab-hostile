# ==============================================================================
# PALEON TEST SITE 7 - Input Variables
# ==============================================================================
# All configurable values are declared here. No hardcoded account IDs, IPs,
# or credentials appear anywhere in the Terraform configuration. Every
# variable has a sensible default for the hostile test target; override via
# terraform.tfvars or -var flags as needed.
# ==============================================================================

# ------------------------------------------------------------------------------
# Region
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region where Site 7 resources are deployed."
  type        = string
  default     = "us-east-1"
}

# ------------------------------------------------------------------------------
# Compute
# ------------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for the Site 7 test target."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Ubuntu 24.04 LTS AMI ID to use for the EC2 instance. Leave empty to auto-discover latest Ubuntu 24.04 LTS in the selected region."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Networking / DNS
# ------------------------------------------------------------------------------

variable "hostname" {
  description = "Primary hostname for the Site 7 test target."
  type        = string
  default     = "paleon-lab-hostile.com"
}

variable "offscope_hostname" {
  description = "Off-scope hostname resolved by the same server as the primary."
  type        = string
  default     = "offscope.paleon-lab-hostile.com"
}

variable "rebind_hostname" {
  description = "DNS-rebinding test hostname (initial A record points to a public test IP)."
  type        = string
  default     = "rebind-test.paleon-lab-hostile.com"
}

variable "route53_zone_id" {
  description = "Route 53 Hosted Zone ID for paleon-lab-hostile.com."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Access Control
# ------------------------------------------------------------------------------

variable "admin_ip" {
  description = "CIDR block allowed to SSH into the Site 7 instance (e.g. 203.0.113.50/32). No other inbound ports should be opened."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Project Label
# ------------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used to prefix all resource names and tags."
  type        = string
  default     = "paleon-site7"
}

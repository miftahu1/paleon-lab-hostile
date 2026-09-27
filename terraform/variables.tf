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
  default     = "eu-west-2"
}

variable "expected_aws_account_id" {
  description = "Required expected AWS account ID for the Sites 1-6 lab account. Site 7 planning/deployment fails if the active account differs."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_aws_account_id))
    error_message = "expected_aws_account_id is required and must be a 12-digit AWS account ID."
  }
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
  description = "Primary apex hostname for the Site 7 test target."
  type        = string
  default     = "paleon-lab-hostile.com"
}

variable "offscope_domain" {
  description = "Operator-supplied separate registered domain used only as SAFE-001 redirect target. Never verify it in Paleon or add it as business-context host."
  type        = string
  default     = ""
  validation {
    condition     = var.offscope_domain != "" && var.offscope_domain != var.hostname && !endswith(var.offscope_domain, ".${var.hostname}")
    error_message = "offscope_domain must be populated with a separate registered domain outside the paleon-lab-hostile.com zone."
  }
}

variable "rebind_hostname" {
  description = "DNS-rebinding test hostname delegated via NS to ns1 (authoritative daemon on the instance)."
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

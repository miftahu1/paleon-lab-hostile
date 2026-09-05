# ==============================================================================
# PALEON TEST SITE 7 - Terraform & Provider Versions
# ==============================================================================
# Pins minimum Terraform version and required providers for reproducibility.
# Uses local backend; no S3 or remote state involved.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

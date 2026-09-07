# ==============================================================================
# PALEON TEST SITE 7 - Outputs
# ==============================================================================
# Exposes key resource attributes for operator use. All values are derived
# from Terraform-managed resources; nothing is hardcoded.
# ==============================================================================

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

output "authorized_public_ip" {
  description = "Elastic IP address assigned to the Site 7 instance."
  value       = aws_eip.paleon-site7-eip.public_ip
}

# ------------------------------------------------------------------------------
# Compute
# ------------------------------------------------------------------------------

output "instance_id" {
  description = "EC2 instance ID for the Site 7 test target."
  value       = aws_instance.paleon-site7.id
}

# ------------------------------------------------------------------------------
# Security
# ------------------------------------------------------------------------------

output "security_group_id" {
  description = "Security group ID attached to the Site 7 instance."
  value       = aws_security_group.paleon-site7-sg.id
}

# ------------------------------------------------------------------------------
# DNS
# ------------------------------------------------------------------------------

output "route53_zone_id" {
  description = "Route 53 Hosted Zone ID used by Site 7."
  value       = var.route53_zone_id
}

output "hostnames" {
  description = "List of all hostnames served by the Site 7 instance."
  value = [
    var.hostname,
    var.offscope_hostname,
    "malformed-http.${var.hostname}",
    "malformed-tls.${var.hostname}",
    var.rebind_hostname,
  ]
}

# ------------------------------------------------------------------------------
# Deployment Summary
# ------------------------------------------------------------------------------

output "deployment_summary" {
  description = "Human-readable summary of the Site 7 deployment."
  value       = <<-EOT

    ============================================================
     PALEON TEST SITE 7 - Deployment Summary
    ============================================================
     Region        : ${var.aws_region}
     Instance ID   : ${aws_instance.paleon-site7.id}
     Instance Type : ${var.instance_type}
     Elastic IP    : ${aws_eip.paleon-site7-eip.public_ip}
     Security Group: ${aws_security_group.paleon-site7-sg.id}
    ------------------------------------------------------------
     Hostnames :
       Primary      : ${var.hostname}          -> ${aws_eip.paleon-site7-eip.public_ip}
       Off-scope    : ${var.offscope_hostname}  -> ${aws_eip.paleon-site7-eip.public_ip}
       Malformed HTTP : malformed-http.${var.hostname} -> ${aws_eip.paleon-site7-eip.public_ip}
       Malformed TLS  : malformed-tls.${var.hostname} -> ${aws_eip.paleon-site7-eip.public_ip}
       Rebind       : ${var.rebind_hostname}    -> NS ns1.${var.hostname}
    ============================================================
     SSH: ssh -i <key>.pem ubuntu@${aws_eip.paleon-site7-eip.public_ip}
    ============================================================
  EOT
}

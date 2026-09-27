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

output "current_aws_account_id" {
  description = "AWS account ID selected by the active credentials. Verify this is the Sites 1-6 lab account."
  value       = data.aws_caller_identity.current.account_id
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
  value = concat(
    [var.hostname],
    [for sub in local.hostile_subdomains : "${sub}.${var.hostname}"],
    ["ns1.${var.hostname}", var.rebind_hostname]
  )
}

output "offscope_target_domain" {
  description = "Separate unverified off-scope destination domain used for scope-escape tests."
  value       = var.offscope_domain
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
     Primary Domain: ${var.hostname} -> ${aws_eip.paleon-site7-eip.public_ip}
     Dedicated Hostile Subdomains:
       imds              : imds.${var.hostname}
       fargate           : fargate.${var.hostname}
       rfc1918           : rfc1918.${var.hostname}
       loopback          : loopback.${var.hostname}
       ipv6              : ipv6.${var.hostname}
       redirect-loop     : redirect-loop.${var.hostname}
       self-loop         : self-loop.${var.hostname}
       large-body        : large-body.${var.hostname}
       slow-body         : slow-body.${var.hostname}
       gzip-body         : gzip-body.${var.hostname}
       observer          : observer.${var.hostname}
       kill-test         : kill-test.${var.hostname}
       ftp-redirect      : ftp-redirect.${var.hostname}
       slow-drip         : slow-drip.${var.hostname}
       slow-tls          : slow-tls.${var.hostname}
       malformed-http    : malformed-http.${var.hostname}
       malformed-tls     : malformed-tls.${var.hostname}
       offscope-redirect : offscope-redirect.${var.hostname} -> https://${var.offscope_domain}/
     DNS Infrastructure:
       ns1 (authoritative): ns1.${var.hostname} -> ${aws_eip.paleon-site7-eip.public_ip}
       rebind-test (NS)  : ${var.rebind_hostname} -> NS ns1.${var.hostname}
    ============================================================
     SSH: ssh -i <key>.pem ubuntu@${aws_eip.paleon-site7-eip.public_ip}
    ============================================================
  EOT
}

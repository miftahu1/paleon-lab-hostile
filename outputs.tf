# PALEON SITE 7 — TERRAFORM OUTPUTS

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.site7.id
}

output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = aws_instance.site7.public_ip
}

output "instance_public_dns" {
  description = "Public DNS name of the instance"
  value       = aws_instance.site7.public_dns
}

output "ssh_connection" {
  description = "SSH connection command"
  value       = "ssh -i ${var.ssh_key_name}.pem ubuntu@${aws_instance.site7.public_ip}"
}

output "http_endpoint" {
  description = "HTTP endpoint URL"
  value       = "http://${aws_instance.site7.public_ip}"
}

output "https_endpoint" {
  description = "HTTPS endpoint URL (if DNS configured)"
  value       = "https://${var.domain_name}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.site7_vpc.id
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.site7_sg.id
}

output "subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.site7_public.id
}

output "iam_role_arn" {
  description = "IAM role ARN"
  value       = aws_iam_role.site7_role.arn
}

output "iam_instance_profile_name" {
  description = "IAM instance profile name"
  value       = aws_iam_instance_profile.site7_profile.name
}

output "deployment_info" {
  description = "Complete deployment information"
  value = {
    instance_id     = aws_instance.site7.id
    public_ip       = aws_instance.site7.public_ip
    public_dns      = aws_instance.site7.public_dns
    ssh_command     = "ssh -i ${var.ssh_key_name}.pem ubuntu@${aws_instance.site7.public_ip}"
    http_url        = "http://${aws_instance.site7.public_ip}"
    https_url       = "https://${var.domain_name}"
    domain          = var.domain_name
    offscope_domain = "offscope.${var.domain_name}"
    rebind_domain   = "rebind-test.${var.domain_name}"
  }
}
# PALEON SITE 7 — Deployment Guide

## Prerequisites

### Local Development
- Terraform >= 1.5.0
- AWS CLI configured with appropriate credentials
- SSH key pair in target region
- Domain name (optional, for HTTPS)

### AWS Permissions Required
The deploying identity needs permissions for:
- EC2 (VPC, subnet, IGW, route tables, security groups, instances)
- IAM (roles, instance profiles, policies)
- Route53 (if configuring DNS records)
- S3 (for Terraform backend state)

## Quick Deployment

```bash
# 1. Initialize Terraform
terraform init

# 2. Review plan
terraform plan -var="ssh_key_name=your-key-name"

# 3. Apply
terraform apply -var="ssh_key_name=your-key-name"

# 4. Verify
./verify.sh
```

## Configuration Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `aws_region` | No | us-east-1 | AWS region |
| `instance_type` | No | t3.medium | EC2 instance type |
| `ami_id` | No | Ubuntu 22.04 | AMI ID for region |
| `ssh_key_name` | **Yes** | — | SSH key pair name |
| `domain_name` | No | paleon-lab-hostile.com | Domain for HTTPS |
| `allowed_ssh_cidr` | No | 0.0.0.0/0 | SSH source restriction |

## DNS Configuration (for HTTPS)

To enable automatic TLS via certbot:

1. Create A records pointing to the instance public IP:
   ```
   paleon-lab-hostile.com     A    <instance-public-ip>
   www.paleon-lab-hostile.com A    <instance-public-ip>
   offscope.paleon-lab-hostile.com A <instance-public-ip>
   rebind-test.paleon-lab-hostile.com A <instance-public-ip>
   ```

2. Wait for DNS propagation, then certbot will succeed on bootstrap.

3. Or run certbot manually after deployment:
   ```bash
   ssh -i your-key.pem ubuntu@<public-ip>
   sudo certbot --nginx -d paleon-lab-hostile.com -d www.paleon-lab-hostile.com
   ```

## Post-Deployment Verification

```bash
# Run verification script (from local machine with SSH access)
./verify.sh

# Or manually check endpoints
curl -I http://<public-ip>/hostile/ssrf/fargate
curl -I http://<public-ip>/hostile/redirect-loop
curl http://<public-ip>/internal/site7-observation
```

## Service Management

### Check Service Status
```bash
ssh -i your-key.pem ubuntu@<public-ip>
sudo systemctl status paleon-site7.service site7-malformed.service site7-rebind-dns.service nginx
```

### View Logs
```bash
# Flask app logs
sudo journalctl -u paleon-site7 -f

# Malformed server logs
sudo journalctl -u site7-malformed -f

# DNS rebinding logs
sudo journalctl -u site7-rebind-dns -f

# Nginx logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# Bootstrap log
sudo cat /var/log/paleon-site7-bootstrap.log
```

### Restart Services
```bash
sudo systemctl restart paleon-site7.service site7-malformed.service site7-rebind-dns.service nginx
```

### Reset to Known State
```bash
sudo ./reset.sh
```

## Endpoint Testing

### SSRF Redirects (Inspect Only - Do Not Follow!)
```bash
# Check Location headers - scanner MUST NOT follow these
curl -I http://<host>/hostile/ssrf/fargate
curl -I http://<host>/hostile/ssrf/imds
curl -I http://<host>/hostile/ssrf/rfc1918
curl -I http://<host>/hostile/ssrf/localhost
curl -I http://<host>/hostile/ssrf/ipv6-loopback
curl -I http://<host>/hostile/ssrf/ipv6-private
```

### Scope Escape
```bash
curl -I http://<host>/hostile/scope-escape
# Should redirect to https://offscope.paleon-lab-hostile.com/
```

### Redirect Loop
```bash
# Follow chain manually (max 5 hops)
curl -I http://<host>/hostile/redirect-loop
curl -I http://<host>/hostile/redirect-loop/2
curl -I http://<host>/hostile/redirect-loop/3
curl -I http://<host>/hostile/redirect-loop/4
curl -I http://<host>/hostile/redirect-loop/5  # Returns 200
```

### Resource Safety
```bash
# Large body - check Content-Length
curl -I http://<host>/hostile/large-body

# Slow body - times out if scanner has no duration limit
curl --max-time 10 http://<host>/hostile/slow-body

# Gzip bomb - check Content-Encoding
curl -I http://<host>/hostile/gzip-bomb
```

### Parser Safety
```bash
# Malformed chunked
curl -I http://<host>/hostile/malformed/chunked

# Malformed banner
curl -I http://<host>/hostile/malformed/banner
```

### Passive Safety
```bash
# Read-only (GET only)
curl http://<host>/hostile/read-only
curl -X POST http://<host>/hostile/read-only  # Should return 405
```

### DNS Rebinding
```bash
# Query DNS twice - should return different IPs
dig @<public-ip> -p 8053 rebind-test.paleon-lab-hostile.com
dig @<public-ip> -p 8053 rebind-test.paleon-lab-hostile.com
```

## Troubleshooting

### Services Not Starting
```bash
# Check systemd status
systemctl status paleon-site7

# Check port conflicts
ss -tlnp | grep -E ':(5000|5001|5002|8053|80|443)'

# Check Python dependencies
pip3 list | grep -E 'flask|gunicorn'
```

### Nginx Issues
```bash
# Test config
nginx -t

# Check upstream
curl http://localhost:5000/health
```

### Certbot Fails
```bash
# Check DNS
host paleon-lab-hostile.com

# Check port 80 accessible
curl -I http://paleon-lab-hostile.com

# Manual certbot
certbot --nginx -d paleon-lab-hostile.com -d www.paleon-lab-hostile.com
```

### Port 8053 (DNS) Not Working
```bash
# Check UDP listening
ss -ulnp | grep 8053

# Test DNS query
dig @localhost -p 8053 rebind-test.paleon-lab-hostile.com
```

## Updating Application Code

1. Edit local files (app.py, malformed_server.py, rebind_dns.py)
2. Re-run validation: `./validate.sh`
3. Re-deploy via Terraform (replaces instance) or copy files and restart:
   ```bash
   scp -i your-key.pem app.py malformed_server.py rebind_dns.py ubuntu@<ip>:/opt/paleon-site7/
   ssh -i your-key.pem ubuntu@<ip> "sudo systemctl restart paleon-site7 site7-malformed site7-rebind-dns"
   ```

## Destroying Infrastructure

```bash
terraform destroy -var="ssh_key_name=your-key-name"
```

## Cost Estimation

| Resource | Monthly Cost (us-east-1) |
|----------|-------------------------|
| t3.medium EC2 | ~$30/month |
| 30GB gp3 EBS | ~$2.40/month |
| Data transfer | Variable |
| **Total** | **~$35-50/month** |

## Security Notes

- Instance runs as non-root `site7` user
- Security group allows only necessary ports
- No secrets stored in user_data or code
- EBS root volume encrypted
- Minimal IAM permissions (EC2 describe only)
- TLS via Let's Encrypt (when DNS configured)

## Support

For issues with the test target itself:
1. Run `./validate.sh` to check configuration
2. Run `./verify.sh` to check runtime
3. Check service logs with `journalctl`
4. Review `/var/log/paleon-site7-bootstrap.log` for bootstrap issues
# PALEON SITE 7 — Deployment Guide

## Prerequisites

### Local Development
- Terraform >= 1.5.0
- AWS CLI configured with appropriate credentials
- SSH key pair in target region
- Domain name (required for HTTPS via certbot)

### AWS Permissions Required
The deploying identity needs permissions for:
- EC2 (security groups, instances, Elastic IPs; read access to the default VPC and its subnet — none are created)
- Route53 (for DNS records)
- S3 (for Terraform backend state)

## Quick Deployment

```bash
# 1. Initialize Terraform
terraform init

# 2. Review plan
terraform plan -var="route53_zone_id=Z123456789" -var="admin_ip=your-ip/32" -var="key_name=your-key-name"

# 3. Apply
terraform apply -var="route53_zone_id=Z123456789" -var="admin_ip=your-ip/32" -var="key_name=your-key-name"

# 4. Verify
./verify.sh
```

## Configuration Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `aws_region` | No | us-east-1 | AWS region |
| `instance_type` | No | t3.micro | EC2 instance type |
| `ami_id` | No | "" (auto-discover Ubuntu 24.04) | Pin a specific AMI, or leave empty to auto-discover |
| `hostname` | No | paleon-lab-hostile.com | Primary hostname / apex domain |
| `key_name` | No | — | Existing EC2 SSH key pair (enables SSH; optional) |
| `offscope_hostname` | No | offscope.paleon-lab-hostile.com | Off-scope subdomain |
| `rebind_hostname` | No | rebind-test.paleon-lab-hostile.com | Rebinding test subdomain |
| `route53_zone_id` | **Yes** | — | Route53 hosted zone ID |
| `admin_ip` | **Yes** | — | Admin IP CIDR for SSH access |

## DNS Configuration

Terraform automatically creates the following Route53 records:
- `paleon-lab-hostile.com` → EIP (A record)
- `offscope.paleon-lab-hostile.com` → EIP (A record)
- `malformed-http.paleon-lab-hostile.com` → EIP (A record)
- `malformed-tls.paleon-lab-hostile.com` → EIP (A record)
- `ns1.paleon-lab-hostile.com` → EIP (A record, glue)
- `rebind-test.paleon-lab-hostile.com` → NS ns1.paleon-lab-hostile.com (NS delegation)

Certbot runs during bootstrap with a 90s timeout, requesting a certificate for the apex and `malformed-http` names only. If it fails, a self-signed SAN certificate is generated as a fallback.

## Post-Deployment Verification

```bash
# Run verification script (from local machine with SSH access)
./verify.sh

# Or manually check endpoints
curl -I http://<public-ip>/hostile/ssrf/fargate
curl -I http://<public-ip>/hostile/redirect-loop/a
# /internal/site7-observation is localhost-only (403 otherwise) — run it ON the instance:
#   ssh ubuntu@<public-ip> curl -s http://127.0.0.1:5000/internal/site7-observation
```

## Service Management

### Check Service Status
```bash
ssh -i your-key.pem ubuntu@<public-ip>
sudo systemctl status paleon-site7.service site7-malformed-server.service site7-rebind-dns.service nginx
```

### View Logs
```bash
# Flask app logs
sudo journalctl -u paleon-site7 -f

# Malformed server logs
sudo journalctl -u site7-malformed-server -f

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
sudo systemctl restart paleon-site7.service site7-malformed-server.service site7-rebind-dns.service nginx
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
curl -I http://<host>/hostile/redirect-loop/a
curl -I http://<host>/hostile/redirect-loop/b
curl -I http://<host>/hostile/redirect-loop/c
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

### Parser Safety (Malformed HTTP via SNI)
```bash
# Malformed chunked encoding
curl -I https://malformed-http.paleon-lab-hostile.com/malformed/chunked

# Malformed banner
curl -I https://malformed-http.paleon-lab-hostile.com/malformed/banner

# Malformed TLS
curl -I https://malformed-tls.paleon-lab-hostile.com/
```

### Passive Safety
```bash
# Read-only (records the method used; returns 200 for every method)
curl http://<host>/hostile/read-only
curl -X POST http://<host>/hostile/read-only   # 200 OK; POST recorded as an observation
```

### DNS Rebinding
```bash
# Query DNS twice - should return different IPs
dig @<public-ip> rebind-test.paleon-lab-hostile.com
dig @<public-ip> rebind-test.paleon-lab-hostile.com
```

## Troubleshooting

### Services Not Starting
```bash
# Check systemd status
systemctl status paleon-site7

# Check port conflicts
ss -tlnp | grep -E ':(5000|8443|9998|9999|53|80|443)'

# Check Python dependencies
pip3 list | grep -E 'flask|dnspython'
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

# Manual certbot (apex + malformed-http only; malformed-tls never completes a
# handshake and rebind-test is delegated for DNS, so neither is certified)
certbot certonly --standalone -d paleon-lab-hostile.com -d malformed-http.paleon-lab-hostile.com
```

### DNS Rebinding Not Working
```bash
# Check TCP/UDP listening on port 53
ss -tlnp | grep :53
ss -ulnp | grep :53

# Test DNS query
dig @localhost rebind-test.paleon-lab-hostile.com
```

## Updating Application Code

1. Edit local files (app.py, malformed_server.py, rebind_dns_server.py)
2. Re-run validation: `./validate.sh`
3. Re-deploy via Terraform (replaces instance) or copy files and restart:
   ```bash
   # Services run the deployed_*.py copies, so update those filenames:
   scp -i your-key.pem app/app.py ubuntu@<ip>:/tmp/deployed_app.py
   scp -i your-key.pem app/malformed_server.py ubuntu@<ip>:/tmp/deployed_malformed_server.py
   scp -i your-key.pem app/rebind_dns_server.py ubuntu@<ip>:/tmp/deployed_rebind_dns_server.py
   ssh -i your-key.pem ubuntu@<ip> "sudo cp /tmp/deployed_*.py /opt/paleon-site7/ && sudo systemctl restart paleon-site7 site7-malformed-server site7-rebind-dns"
   ```

## Destroying Infrastructure

```bash
terraform destroy -var="key_name=your-key-name" -var="admin_ip=your-ip/32" -var="route53_zone_id=Z123456789"
```

## Cost Estimation

| Resource | Monthly Cost (us-east-1) |
|----------|-------------------------|
| t3.micro EC2 | ~$8.50/month |
| 20GB gp3 EBS | ~$1.60/month |
| Elastic IP (attached) | $0/month |
| Data transfer | Variable |
| Route53 queries | ~$0.40/month |
| **Total** | **~$10-15/month** |

## Security Notes

- Instance runs as non-root `site7` user
- Security group allows only necessary ports (80, 443, 22 admin, 53 TCP/UDP)
- No secrets stored in user_data or code
- EBS root volume encrypted
- No IAM instance profile attached (minimal permissions)
- TLS via Let's Encrypt (when DNS configured) with self-signed fallback
- Private key permissions: 640 (owner root, group site7-tls; site7 and www-data are members)

## Support

For issues with the test target itself:
1. Run `./validate.sh` to check configuration
2. Run `./verify.sh` to check runtime
3. Check service logs with `journalctl`
4. Review `/var/log/paleon-site7-bootstrap.log` for bootstrap issues
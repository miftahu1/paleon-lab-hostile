# PALEON SITE 7 — Operations & Maintenance Guide

## Daily Operations

### Health Checks
```bash
# Quick health check
curl -s http://localhost:5000/health

# Full endpoint validation
./verify.sh

# Check all services
systemctl is-active paleon-site7.service site7-malformed.service site7-rebind-dns.service nginx
```

### Log Monitoring
```bash
# Follow all service logs
journalctl -u paleon-site7 -u site7-malformed -u site7-rebind-dns -f

# Nginx access logs
tail -f /var/log/nginx/access.log

# Error logs
tail -f /var/log/nginx/error.log
```

## Weekly Maintenance

### Log Rotation
Observation logs are daily JSONL files in `/var/lib/site7/observations/`. They are not automatically rotated.

```bash
# Archive old logs (older than 30 days)
find /var/lib/site7/observations -name "*.jsonl" -mtime +30 -exec gzip {} \;

# Or move to archive
mkdir -p /var/lib/site7/observations/archive
find /var/lib/site7/observations -name "*.jsonl" -mtime +30 -exec mv {} /var/lib/site7/observations/archive/ \;
```

### Disk Space Check
```bash
df -h /var/lib/site7
df -h /opt/paleon-site7
```

### Certificate Renewal (if HTTPS enabled)
```bash
# Check certificate expiry
openssl x509 -checkend 2592000 -noout -in /etc/letsencrypt/live/paleon-lab-hostile.com/fullchain.pem

# Manual renewal
certbot renew --nginx

# Auto-renewal is configured via systemd timer
systemctl status certbot.timer
```

## Incident Response

### Service Down

**Flask App (paleon-site7)**
```bash
# Check status
systemctl status paleon-site7

# View recent logs
journalctl -u paleon-site7 -n 50

# Restart
systemctl restart paleon-site7

# If port conflict
ss -tlnp | grep :5000
```

**Malformed Server**
```bash
systemctl status site7-malformed
journalctl -u site7-malformed -n 50
systemctl restart site7-malformed
```

**DNS Rebinding**
```bash
systemctl status site7-rebind-dns
journalctl -u site7-rebind-dns -n 50
systemctl restart site7-rebind-dns

# Test DNS
dig @localhost -p 8053 rebind-test.paleon-lab-hostile.com
```

**Nginx**
```bash
systemctl status nginx
nginx -t
journalctl -u nginx -n 50
systemctl restart nginx
```

### Port Conflicts
```bash
# Check what's using expected ports
ss -tlnp | grep -E ':(5000|5001|5002|8053|80|443)'

# Kill conflicting process (if not ours)
kill -9 <PID>

# Restart our services
systemctl restart paleon-site7 site7-malformed site7-rebind-dns nginx
```

### High Memory/CPU
```bash
# Check resource usage
top -p $(pgrep -f "paleon-site7|malformed_server|rebind_dns")

# Restart if needed
systemctl restart paleon-site7 site7-malformed site7-rebind-dns
```

### Observation Log Issues
```bash
# Check log directory
ls -la /var/lib/site7/observations/

# Check permissions
ls -la /var/lib/site7/

# Fix permissions if needed
chown -R site7:site7 /var/lib/site7/
chmod 755 /var/lib/site7/observations
```

## Reset Procedures

### Soft Reset (Clear State, Keep Services)
```bash
./reset.sh
```
This:
- Stops all Site 7 services
- Clears observation logs (`*.jsonl`)
- Resets DNS rebinding state
- Clears temp directory
- Restarts all services

### Hard Reset (Full Redeploy)
```bash
# From local machine
terraform apply -replace=aws_instance.site7

# Or manually on instance
sudo systemctl stop paleon-site7 site7-malformed site7-rebind-dns nginx
sudo rm -rf /opt/paleon-site7/* /var/lib/site7/*
# Re-run bootstrap or re-deploy via Terraform
```

## Backup & Recovery

### What to Backup
- **Terraform State**: Stored in S3 backend (automatic)
- **Observation Logs**: `/var/lib/site7/observations/` (optional, for analysis)
- **Rebind State**: `/var/lib/site7/rebind-state.json` (optional)

### Backup Commands
```bash
# Backup observations
tar -czf /tmp/site7-observations-$(date +%Y%m%d).tar.gz /var/lib/site7/observations/

# Backup rebind state
cp /var/lib/site7/rebind-state.json /tmp/rebind-state-$(date +%Y%m%d).json

# Copy to S3 (if configured)
aws s3 cp /tmp/site7-observations-$(date +%Y%m%d).tar.gz s3://your-bucket/backups/site7/
```

### Recovery
```bash
# Restore observations
tar -xzf site7-observations-20260904.tar.gz -C /

# Restore rebind state
cp rebind-state-20260904.json /var/lib/site7/rebind-state.json
chown site7:site7 /var/lib/site7/rebind-state.json
```

## Security Operations

### SSH Access
```bash
# Only allow key-based auth (enforced by cloud-init)
# Restrict SSH CIDR in security group if possible

# Audit SSH access
grep "Accepted publickey" /var/log/auth.log
```

### Package Updates
```bash
# Update system packages (monthly)
apt-get update && apt-get upgrade -y

# Restart services after kernel updates
needs-restarting -r && systemctl reboot
```

### Vulnerability Scanning
```bash
# Scan container/instance (if using containers)
# Not applicable - bare metal instance

# Check for listening services
ss -tlnp
```

## Performance Tuning

### Flask Workers (if using gunicorn)
Current setup uses Flask development server. For production load:
```bash
# Install gunicorn (already in requirements.txt)
# Modify paleon-site7.service:
ExecStart=/usr/bin/gunicorn --workers 4 --bind 0.0.0.0:5000 app:app
```

### Nginx Tuning
```nginx
# In /etc/nginx/nginx.conf or site7.conf
worker_processes auto;
worker_connections 1024;

# Proxy buffers for large/slow responses
proxy_buffering off;
proxy_request_buffering off;
proxy_read_timeout 300s;
proxy_send_timeout 300s;
```

### System Limits
```bash
# Increase file descriptors for site7 user
echo "site7 soft nofile 65536" >> /etc/security/limits.conf
echo "site7 hard nofile 65536" >> /etc/security/limits.conf
```

## Monitoring & Alerting

### Key Metrics to Monitor
| Metric | Warning | Critical |
|--------|---------|----------|
| Service uptime | < 99.9% | < 99% |
| Disk usage /var/lib/site7 | > 80% | > 90% |
| Memory usage | > 80% | > 90% |
| CPU usage | > 80% | > 90% |
| Certificate expiry | < 30 days | < 7 days |
| Failed endpoint checks | > 0 | > 0 |

### Custom Checks
```bash
# Endpoint health (run every 5 min)
curl -f http://localhost:5000/health || alert

# DNS rebinding functional
dig @localhost -p 8053 rebind-test.paleon-lab-hostile.com +short | grep -E "203\.0\.113\.42|10\.0\.0\.50" || alert

# Observation logging working
curl -s http://localhost:5000/internal/site7-observation | jq -e '.observations | length > 0' || alert
```

## Troubleshooting Reference

### Common Issues

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| 502 Bad Gateway | Flask app not running | `systemctl restart paleon-site7` |
| 504 Gateway Timeout | Slow-body endpoint, proxy timeout | Increase nginx proxy_read_timeout |
| DNS SERVFAIL | Rebinding DNS not running | `systemctl restart site7-rebind-dns` |
| Certbot fails | DNS not propagated | Wait for DNS, check `host domain.com` |
| Port already in use | Stale process | `ss -tlnp`, kill stale PID |
| Permission denied | Wrong user on files | `chown -R site7:site7 /var/lib/site7 /opt/paleon-site7` |

### Debug Mode
```bash
# Enable Flask debug (temporary only!)
sed -i 's/debug=False/debug=True/' /opt/paleon-site7/app.py
systemctl restart paleon-site7
# REMEMBER TO DISABLE AFTER DEBUGGING
```

### Log Analysis
```bash
# Count SSRF attempts by type
grep "ssrf_redirect_attempt" /var/lib/site7/observations/*.jsonl | jq -r '.details.target' | sort | uniq -c

# Top scanning IPs
grep "client_ip" /var/lib/site7/observations/*.jsonl | jq -r '.client_ip' | sort | uniq -c | sort -rn | head -20

# Timeline of attacks
grep "timestamp" /var/lib/site7/observations/*.jsonl | head -5
```

## Upgrade Procedures

### Application Code Updates
```bash
# 1. Update local files
# 2. Validate
./validate.sh

# 3. Deploy via Terraform (recommended - immutable)
terraform apply

# OR deploy in-place (faster, but mutable)
scp app.py malformed_server.py rebind_dns.py ubuntu@<ip>:/opt/paleon-site7/
ssh ubuntu@<ip> "sudo systemctl restart paleon-site7 site7-malformed site7-rebind-dns"
```

### Terraform Version Upgrade
```bash
# Check current version
terraform version

# Upgrade Terraform binary
# Update required_version in main.tf if needed
terraform init -upgrade
```

### OS Upgrade (Major)
```bash
# Not recommended in-place for test targets
# Instead: terraform destroy && terraform apply with new AMI
```

## Contact & Escalation

- **Primary**: Infrastructure team
- **Escalation**: Security team (for scanner validation issues)
- **Documentation**: This repository

## Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-09-04 | Initial deployment | Paleon Team |
# PALEON SITE 7 — Operations & Maintenance Guide

## Daily Operations

### Health Checks
```bash
# Quick health check
curl -s http://localhost:5000/health

# Full endpoint validation
./verify.sh

# Check all services
systemctl is-active paleon-site7.service site7-malformed-server.service site7-rebind-dns.service nginx
```

### Log Monitoring
```bash
# Follow all service logs
journalctl -u paleon-site7 -u site7-malformed-server -u site7-rebind-dns -f

# Nginx access logs
tail -f /var/log/nginx/access.log

# Error logs
tail -f /var/log/nginx/error.log
```

## Weekly Maintenance

### Log Rotation
Observations are **not** written to disk — they live in an in-memory `deque(maxlen=100)` inside the Flask process and are discarded on restart, so there are no observation files to rotate. Service output goes to the systemd journal; bound it with the standard journald controls if needed:

```bash
# Cap journal size
journalctl --vacuum-size=200M

# Or bound by age
journalctl --vacuum-time=30d
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
systemctl status site7-malformed-server
journalctl -u site7-malformed-server -n 50
systemctl restart site7-malformed-server
```

**DNS Rebinding**
```bash
systemctl status site7-rebind-dns
journalctl -u site7-rebind-dns -n 50
systemctl restart site7-rebind-dns

# Test DNS
dig @localhost rebind-test.paleon-lab-hostile.com
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
ss -tlnp | grep -E ':(5000|8443|9998|9999|53|80|443)'

# Kill conflicting process (if not ours)
kill -9 <PID>

# Restart our services
systemctl restart paleon-site7 site7-malformed-server site7-rebind-dns nginx
```

### High Memory/CPU
```bash
# Check resource usage
top -p $(pgrep -f "paleon-site7|malformed_server|rebind_dns")

# Restart if needed
systemctl restart paleon-site7 site7-malformed-server site7-rebind-dns
```

### Observation Issues
Observations are held in memory and served from `GET /internal/site7-observation` (localhost-only). There is no observation directory to inspect or chown.

```bash
# View current in-memory observations (run ON the instance; endpoint is localhost-only)
curl -s http://127.0.0.1:5000/internal/site7-observation | jq .

# If empty, generate traffic then re-check
curl -s -o /dev/null http://127.0.0.1:5000/hostile/ssrf/imds
curl -s http://127.0.0.1:5000/internal/site7-observation | jq '.observations | length'

# Observations reset to empty whenever the Flask service restarts
systemctl restart paleon-site7
```

## Reset Procedures

### Soft Reset (Clear State, Keep Services)
```bash
./reset.sh
```
This (see `reset.sh`):
- Stops the Site 7 services
- Resets DNS rebinding state to the initial public / zero-count value (`/var/lib/site7/rebind-state.json`)
- Restarts all services (which discards the in-memory observation deque)
- Runs a health gate: verifies every service is active, all expected ports listen, and `/health` responds

### Hard Reset (Full Redeploy)
```bash
# From local machine
terraform apply -replace=aws_instance.paleon-site7

# Or manually on instance
sudo systemctl stop paleon-site7 site7-malformed-server site7-rebind-dns nginx
sudo rm -rf /opt/paleon-site7/* /var/lib/site7/*
# Re-run bootstrap or re-deploy via Terraform
```

## Backup & Recovery

Site 7 is a stateless test target, so there is almost nothing to back up:

### What to Backup
- **Terraform State**: stored in the S3 backend (authoritative; recreates all infrastructure)
- **Application code**: this Git repository
- **Observations**: nothing to back up — they are in-memory only and intentionally ephemeral
- **Rebind state** (`/var/lib/site7/rebind-state.json`): a transient DNS counter that `reset.sh` regenerates, so a backup is not needed

### Recovery
```bash
# Full rebuild from code (preferred): re-run Terraform
terraform apply

# Or restore a known-good runtime state on the instance
sudo ./reset.sh
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

### Flask Workers
The deployed unit runs the app directly (`ExecStart=/usr/bin/python3 /opt/paleon-site7/deployed_app.py`) with the threaded Werkzeug server (`app.run(threaded=True)`), which is sufficient for a single-instance test target. If you ever need more concurrency, `gunicorn` is present in `requirements.txt` and can back the same WSGI app:
```bash
# Optional: switch paleon-site7.service ExecStart to gunicorn
ExecStart=/usr/bin/gunicorn --workers 4 --bind 127.0.0.1:5000 deployed_app:app
```

### Nginx Tuning
```nginx
# In /etc/nginx/nginx.conf
worker_processes auto;
worker_connections 1024;

# Proxy buffers for large/slow responses
proxy_buffering off;
proxy_request_buffering off;
proxy_read_timeout 20s;
proxy_send_timeout 20s;
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
dig @localhost rebind-test.paleon-lab-hostile.com +short | grep -E "<EIP>|192\.168\.1\.1" || alert

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
sed -i 's/debug=False/debug=True/' /opt/paleon-site7/deployed_app.py
systemctl restart paleon-site7
# REMEMBER TO DISABLE AFTER DEBUGGING
```

### Log Analysis
Observations come from the in-memory endpoint (localhost-only), not from files:
```bash
# Snapshot current observations
curl -s http://127.0.0.1:5000/internal/site7-observation > /tmp/obs.json

# Count SSRF attempts by target
jq -r '.observations[] | select(.event_type=="ssrf_redirect_attempt") | .details.target' /tmp/obs.json | sort | uniq -c

# Top scanning IPs
jq -r '.observations[].client_ip' /tmp/obs.json | sort | uniq -c | sort -rn | head -20

# Most recent events
jq -r '.observations[-5:][] | "\(.timestamp) \(.event_type)"' /tmp/obs.json
```
Note: the deque holds at most 100 entries and is cleared on restart, so this is a live snapshot, not a historical archive.

## Upgrade Procedures

### Application Code Updates
```bash
# 1. Update local files
# 2. Validate
./validate.sh

# 3. Deploy via Terraform (recommended - immutable)
terraform apply

# OR deploy in-place (faster, but mutable)
# Services execute the deployed_*.py copies, so land the files under those names:
scp app/app.py ubuntu@<ip>:/tmp/deployed_app.py
scp app/malformed_server.py ubuntu@<ip>:/tmp/deployed_malformed_server.py
scp app/rebind_dns_server.py ubuntu@<ip>:/tmp/deployed_rebind_dns_server.py
ssh ubuntu@<ip> "sudo cp /tmp/deployed_*.py /opt/paleon-site7/ && sudo systemctl restart paleon-site7 site7-malformed-server site7-rebind-dns"
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
| 2026-09-07 | Updated for final architecture | Paleon Team |
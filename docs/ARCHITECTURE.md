# PALEON SITE 7 — Architecture Documentation

## System Overview

Paleon Site 7 is a hostile adversarial test target deployed as a single EC2 instance running multiple services that simulate dangerous conditions for scanner resilience validation.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AWS INFRASTRUCTURE                           │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    VPC (10.7.0.0/16)                          │   │
│  │  ┌────────────────────────────────────────────────────────┐  │   │
│  │  │           Public Subnet (10.7.1.0/24)                   │  │   │
│  │  │  ┌──────────────────────────────────────────────────┐  │  │   │
│  │  │  │              EC2 Instance (t3.medium)             │  │  │   │
│  │  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────────┐  │  │  │   │
│  │  │  │  │ nginx   │ │Flask App│ │Malformed│ │Rebind  │  │  │  │   │
│  │  │  │  │ :80/443 │ │ :5000   │ │ :5001   │ │DNS :53 │  │  │  │   │
│  │  │  │  └─────────┘ └─────────┘ └─────────┘ └────────┘  │  │  │   │
│  │  │  │  ┌──────────────────────────────────────────────┐  │  │  │   │
│  │  │  │  │           /var/lib/site7/                      │  │  │   │
│  │  │  │  │  observations/  rebind-state.json  temp/      │  │  │   │
│  │  │  │  └──────────────────────────────────────────────┘  │  │  │   │
│  │  │  └──────────────────────────────────────────────────┘  │  │   │
│  │  └────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

### 1. Nginx Reverse Proxy (Ports 80, 443)
- Terminates TLS (when certbot configured)
- Proxies to Flask app on localhost:5000
- Hosts offscope subdomain on separate server block
- Configures proxy timeouts for slow-body endpoint (300s)

### 2. Main Flask Application (Port 5000)
Primary hostile endpoint server implementing all resilience test endpoints:

**SSRF Endpoints** — Return HTTP 302 redirects to dangerous destinations:
- Link-local metadata endpoints (169.254.x.x)
- RFC1918 private ranges (10.x.x.x)
- Loopback addresses (127.0.0.1, [::1])
- IPv6 ULA ranges (fc00::/7)

**Scope Escape** — Redirects to offscope.paleon-lab-hostile.com

**Redirect Loop** — 5-step redirect chain terminating at step 5

**Resource Exhaustion** — Large body, slow body, gzip bomb

**Malformed Responses** — Invalid chunked encoding, invalid status codes

**Passive Safety** — Read-only endpoint rejecting state-changing methods

**Observation Logging** — All access logged to JSONL files in /var/lib/site7/observations/

### 3. Malformed Server (Port 5001)
Raw TCP server serving additional malformed HTTP responses:
- Missing status line
- Invalid header format
- Missing CRLF termination
- Bad chunk sizes
- Premature connection close
- Null bytes in headers

### 4. DNS Rebinding Simulator (Port 5002 HTTP, 8053 UDP)
- UDP DNS server on port 8053
- First query returns public IP (203.0.113.42)
- Subsequent queries return private IP (10.0.0.50)
- HTTP endpoint on port 5002 for testing
- State persisted to /var/lib/site7/rebind-state.json

## Data Flow

```
Scanner Request
      │
      ▼
┌─────────┐     ┌──────────────┐     ┌──────────────────┐
│  nginx  │────▶│  Flask App   │────▶│  Log Observation │
│ :80/443 │     │  :5000       │     │  /var/lib/site7/ │
└─────────┘     └──────────────┘     └──────────────────┘
                     │
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
  ┌─────────┐ ┌──────────┐ ┌──────────────┐
  │Malformed│ │ DNS Re-  │ │  Off-scope   │
  │ :5001   │ │ bind :53 │ │  nginx vhost │
  └─────────┘ └──────────┘ └──────────────┘
```

## Security Model

### Threat Model
Site 7 is designed to test scanner behavior, not to be secure itself. It intentionally:
- Redirects to metadata endpoints
- Serves resource-exhaustion payloads
- Returns malformed HTTP
- Simulates DNS rebinding

### Isolation
- Runs in dedicated VPC (10.7.0.0/16)
- Security group restricts inbound to expected ports only
- Runs as unprivileged 'site7' user
- No access to production systems or data

### Scanner Safety Requirements
Scanners MUST:
1. **Inspect, don't follow** — Check Location headers on 3xx responses but never follow redirects to private/link-local/off-scope destinations
2. **Bound resources** — Limit response size (max 10MB), duration (max 30s), decompression ratio
3. **Parse defensively** — Handle malformed HTTP without crashing
4. **Re-validate DNS** — On reconnect, re-resolve hostnames; refuse private IPs after rebinding
5. **Terminate cleanly** — Handle SIGTERM/SIGKILL without orphan processes
6. **Stay in scope** — Never request offscope.paleon-lab-hostile.com

## State Management

### Observations
- Stored as JSONL files: `/var/lib/site7/observations/observations_YYYYMMDD.jsonl`
- Each entry: timestamp, event_type, client_ip, user_agent, details
- Accessed via `GET /internal/site7-observation`

### DNS Rebinding State
- Stored as JSON: `/var/lib/site7/rebind-state.json`
- Format: `{"query_count": N, "state": "public|rebound"}`
- Reset by reset.sh

### Temporary Files
- Directory: `/var/lib/site7/temp/`
- Cleared on reset

## Service Management

### Systemd Units
| Unit | Description | Dependencies |
|------|-------------|--------------|
| paleon-site7.service | Main Flask app | network.target |
| site7-malformed.service | Malformed TCP server | network.target, paleon-site7.service |
| site7-rebind-dns.service | DNS + HTTP rebinding | network.target |
| nginx.service | Reverse proxy | network.target |

### Start Order
1. site7-rebind-dns.service (independent)
2. site7-malformed.service (depends on paleon-site7)
3. paleon-site7.service (main app)
4. nginx.service (proxies to paleon-site7)

## Network Ports

| Port | Protocol | Service | Purpose |
|------|----------|---------|---------|
| 22 | TCP | SSH | Instance management |
| 53 | UDP | DNS | Standard DNS (not used by site7) |
| 80 | TCP | nginx | HTTP (redirects to HTTPS) |
| 443 | TCP | nginx | HTTPS (TLS termination) |
| 5000 | TCP | Flask | Main app (internal, proxied) |
| 5001 | TCP | Malformed | Additional malformed responses |
| 5002 | TCP | Rebind HTTP | DNS rebinding test endpoint |
| 8053 | UDP | Rebind DNS | DNS rebinding simulator |

## Deployment Architecture

### Terraform Resources
- **VPC** with single public subnet
- **Internet Gateway** for public access
- **Security Group** with least-privilege ingress rules
- **EC2 Instance** with IAM instance profile
- **IAM Role** with minimal permissions (EC2 describe only)
- **Route53 Records** (optional, commented out)

### Bootstrap (user_data.sh)
Idempotent bootstrap script that:
1. Updates system and installs packages
2. Creates site7 user and directories
3. Deploys application code inline
4. Installs Python dependencies
5. Creates systemd service units
6. Configures nginx with virtual hosts
7. Starts all services
8. Validates endpoints
9. Attempts certbot TLS setup

## Resilience Test Mapping

Each endpoint maps to a specific resilience test in expected.yaml:

| Test ID | Endpoint(s) | Validation Method |
|---------|-------------|-------------------|
| SSRF-001 | /hostile/ssrf/fargate | Check 302 Location header contains 169.254.170.2 |
| SSRF-002 | /hostile/ssrf/imds | Check 302 Location header contains 169.254.169.254 |
| SSRF-003 | /hostile/ssrf/rfc1918 | Check 302 Location header contains 10.0.0.1 |
| SSRF-004 | /hostile/ssrf/localhost, ipv6-loopback, ipv6-private | Check 302 Location headers |
| SAFE-001 | /hostile/scope-escape | Check 302 Location to offscope subdomain |
| SAFE-002 | /hostile/redirect-loop | Follow chain to step 5 (max 5 hops) |
| SAFE-003 | /hostile/large-body, slow-body, gzip-bomb | Check Content-Length, timing, Content-Encoding |
| SAFE-004 | /hostile/malformed/chunked, banner | Verify no crash, defensive parsing |
| SAFE-005 | /hostile/read-only | Verify only GET allowed |
| SAFE-006 | /hostile/kill-test | Verify clean termination |
| SAFE-007 | rebind-test.paleon-lab-hostile.com | Query DNS twice, verify different IPs |

## Monitoring & Observability

### Logs
- **Systemd journal**: `journalctl -u paleon-site7 -f`
- **Nginx access/error**: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`
- **Bootstrap**: `/var/log/paleon-site7-bootstrap.log`
- **Observations**: `/var/lib/site7/observations/*.jsonl`

### Health Checks
- `GET /health` → `{"status": "healthy", "service": "paleon-site7"}`
- `GET /internal/site7-observation` → Recent observation logs

## Failure Scenarios & Mitigations

| Failure | Detection | Mitigation |
|---------|-----------|------------|
| Flask app crash | systemd restart (Restart=always) | Auto-restart within 5s |
| Malformed server crash | systemd restart | Auto-restart |
| DNS rebinding crash | systemd restart | Auto-restart |
| Nginx config error | nginx -t in bootstrap | Fail fast in bootstrap |
| Port conflict | ss -tlnp validation | Explicit port allocation |
| Certbot failure | Non-fatal, logged | Continue with HTTP only |
| DNS not configured | host check | Skip HTTPS gracefully |

## Scaling Considerations

Current design is single-instance. For higher load:
- Add ALB in front of ASG
- Externalize observation storage (S3/DynamoDB)
- Shared rebind state via Redis
- Separate malformed/rebind instances

## Disaster Recovery

- **RPO**: Observations lost since last reset (acceptable for test target)
- **RTO**: ~5 minutes (terraform apply + bootstrap)
- **Backup**: Terraform state in S3, infrastructure as code
- **Reset**: `./reset.sh` restores known state in ~30 seconds

## Security Hardening

- All services run as `site7` user (non-root)
- Minimal IAM permissions
- Encrypted EBS root volume
- Security group allows only necessary ports
- No secrets in user_data or code
- TLS via certbot (Let's Encrypt)
# PALEON SITE 7 — Architecture Documentation

## System Overview

Paleon Site 7 is a hostile adversarial test target deployed as a single EC2 instance running multiple services that simulate dangerous conditions for scanner resilience validation.

```
┌────────────────────────────────────────────────────────────────────┐
│                        AWS INFRASTRUCTURE                          │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    VPC (default)                              │  │
│  │  ┌────────────────────────────────────────────────────────┐  │  │
│  │  │           Public Subnet                                 │  │  │
│  │  │  ┌──────────────────────────────────────────────────┐  │  │  │
│  │  │  │              EC2 Instance (t3.micro)             │  │  │  │
│  │  │  │  ┌─────────┐ ┌─────────┐ ┌──────────┐ ┌────────┐ │  │  │  │
│  │  │  │  │ nginx   │ │Flask App│ │Malformed │ │Rebind  │ │  │  │  │
│  │  │  │  │ :80/443 │ │:5000    │ │:9998/9999│ │DNS :53 │ │  │  │  │
│  │  │  │  └─────────┘ └─────────┘ └──────────┘ └────────┘ │  │  │  │
│  │  │  │  ┌────────────────────────────────────────────┐  │  │  │  │
│  │  │  │  │           /var/lib/site7/                  │  │  │  │  │ 
│  │  │  │  │  rebind-state.json  (DNS query counter)    │  │  │  │  │
│  │  │  │  └────────────────────────────────────────────┘  │  │  │  │
│  │  │  └──────────────────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

### 1. Nginx Reverse Proxy (Ports 80, 443)
- Terminates TLS (when certbot configured)
- SNI routing on port 443:
  - `malformed-tls.*` → 127.0.0.1:9998 (raw malformed TLS)
  - `malformed-http.*` → 127.0.0.1:9999 (valid TLS + malformed HTTP)
  - default → 127.0.0.1:8443 → Flask app on 127.0.0.1:5000
- Port 80: HTTP to HTTPS redirect
- Configures proxy timeouts for slow-body endpoint (proxy_read_timeout 20s)

### 2. Internal HTTPS Termination (Port 8443)
- Listens on 127.0.0.1:8443 with TLS
- Proxies to Flask app on 127.0.0.1:5000
- Used as default backend for nginx SNI routing

### 3. Main Flask Application (Port 5000, 127.0.0.1 only)
Primary hostile endpoint server implementing all resilience test endpoints:

**SSRF Endpoints** — Return HTTP 302 redirects to dangerous destinations:
- Link-local metadata endpoints (169.254.x.x)
- RFC1918 private ranges (10.x.x.x)
- Loopback addresses (127.0.0.1, [::1])
- IPv6 ULA ranges (fc00::/7)

**Scope Escape** — Redirects to offscope.paleon-lab-hostile.com

**Redirect Loop** — 3-node redirect cycle (a→b→c→a, never terminates; scanner must cap hops)

**Resource Exhaustion** — Large body (20MB max), slow body (15s max), gzip bomb (10MB decompressed)

**Passive Safety** — "Read-only" endpoint that records the method and returns 200 for every verb (GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS); no method is rejected

**Kill Test** — Holds connection for 15 seconds

**Observation Logging** — All access recorded to an in-memory `deque(maxlen=100)`; no on-disk JSONL, no temp files

### 4. Malformed TLS Server (Port 9998, 127.0.0.1 only)
Raw TCP server serving garbled TLS ServerHello:
- Reads ClientHello
- Sends malformed ServerHello with garbage payload
- Connection cap: 10 concurrent
- Idle timeout: 30s

### 5. Malformed HTTP Server (Port 9999, 127.0.0.1 only)
Valid TLS handshake → Raw malformed HTTP bytes:
- `/malformed/chunked` — Invalid chunked encoding (GARBAGE chunk size)
- `/malformed/banner` — Control chars in header (\\x00-\\x03), binary data
- Connection cap: 10 concurrent
- Idle timeout: 30s
- Thread pool with bounded concurrency

### 6. DNS Rebinding Simulator (Port 53 TCP/UDP, 0.0.0.0)
Authoritative DNS server for rebind-test.paleon-lab-hostile.com:
- First query: returns public EIP (from SITE7_EIP env var)
- Subsequent queries: returns 192.168.1.1
- TTL: 0 (forces re-resolution)
- Sets AA flag (0x8400), clears RA flag
- State persisted to /var/lib/site7/rebind-state.json
- Bounded thread pool for both UDP and TCP (10 workers each), each gated by a non-blocking semaphore
- Runs as `site7` user with CAP_NET_BIND_SERVICE

## Data Flow

```
Scanner Request
      │
      ▼
┌─────────┐     SNI Routing
│  nginx  │──────────────────────────────────────┐
│ :80/443 │                                       │
└─────────┘                                       │
      │                                           │
      ▼                                           ▼
┌─────────┐                              ┌─────────────┐
│ Default │                              │ Malformed   │
│ Backend │                              │ Backends    │
│ :8443   │                              │ :9998/:9999 │
└────┬────┘                              └──────┬──────┘
     │                                           │
     ▼                                           ▼
┌─────────┐                              ┌─────────────┐
│  Flask  │                              │  Raw TLS/   │
│ App :5k │                              │  Malformed  │
└────┬────┘                              │   HTTP      │
     │                                   └─────────────┘
     ▼
┌──────────────────┐
│  Log Observation │
│  (in-memory)     │
└──────────────────┘
     │
     ▼
┌──────────┐
│ DNS      │
│ Rebinding│
│   :53    │
└──────────┘
```

## Security Model

### Threat Model
Site 7 is designed to test scanner behavior, not to be secure itself. It intentionally:
- Redirects to metadata endpoints
- Serves resource-exhaustion payloads
- Returns malformed HTTP/TLS
- Simulates DNS rebinding

### Isolation
- Runs in default VPC with single public subnet
- Security group restricts inbound to expected ports only
- Runs as unprivileged `site7` user
- No access to production systems or data
- No IAM instance profile attached
- Reboot-persistent host egress firewall REJECTs the `site7` user's outbound traffic to RFC1918, link-local, and metadata ranges (see docs/isolation.md §2)

### Scanner Safety Requirements
Scanners MUST:
1. **Inspect, don't follow** — Check Location headers on 3xx responses but never follow redirects to private/link-local/off-scope destinations
2. **Bound resources** — Limit response size (max 20MB), duration (max 15s), decompression ratio
3. **Parse defensively** — Handle malformed HTTP/TLS without crashing
4. **Re-validate DNS** — On reconnect, re-resolve hostnames; refuse private IPs after rebinding
5. **Terminate cleanly** — Handle SIGTERM/SIGKILL without orphan processes
6. **Stay in scope** — Never request offscope.paleon-lab-hostile.com

## State Management

### Observations
- Stored **in memory only**: a `collections.deque(maxlen=100)` inside the Flask process
- Each entry: timestamp, event_type, client_ip, user_agent, details
- Accessed via `GET /internal/site7-observation` (localhost-only; 403 from any other source)
- No on-disk JSONL and no temp directory; all observations are discarded on process restart

### DNS Rebinding State
- Stored as JSON: `/var/lib/site7/rebind-state.json`
- Format: `{"query_count": N, "total_a_queries": N, "state": "public|mixed", "clients": {"<ip>": count}, "last_query": <unix_ts>}` (per-client counts; `state` is `public` until the first query, then `mixed`)
- Reset by reset.sh

## Service Management

### Systemd Units
| Unit | Description | Dependencies |
|------|-------------|--------------|
| site7-egress-firewall.service | Oneshot: installs iptables/ip6tables owner-uid egress REJECT for the `site7` user | Before=network-pre.target (re-run every boot) |
| paleon-site7.service | Main Flask app | network.target |
| site7-malformed-server.service | Malformed TLS/HTTP servers | network.target |
| site7-rebind-dns.service | DNS rebinding simulator | network.target |
| nginx.service | Reverse proxy | network.target |

### Start Order
1. site7-rebind-dns.service (independent)
2. site7-malformed-server.service
3. paleon-site7.service (main app)
4. nginx.service (proxies to paleon-site7)

## Network Ports

| Port | Protocol | Bind Address | Service | Purpose |
|------|----------|--------------|---------|---------|
| 22 | TCP | 0.0.0.0 | SSH | Instance management (admin_ip only) |
| 53 | TCP | 0.0.0.0 | DNS Rebinding | Authoritative DNS for rebind-test |
| 53 | UDP | 0.0.0.0 | DNS Rebinding | Authoritative DNS for rebind-test |
| 80 | TCP | 0.0.0.0 | nginx | HTTP (redirects to HTTPS) |
| 443 | TCP | 0.0.0.0 | nginx | HTTPS (SNI routing) |
| 5000 | TCP | 127.0.0.1 | Flask | Main app (internal) |
| 8443 | TCP | 127.0.0.1 | nginx | Internal HTTPS termination |
| 9998 | TCP | 127.0.0.1 | Malformed | Raw malformed TLS |
| 9999 | TCP | 127.0.0.1 | Malformed | Valid TLS + malformed HTTP |

## Deployment Architecture

### Terraform Resources
- **Default VPC + subnet** (read via data sources — neither the VPC nor its Internet Gateway is created by this stack)
- **Security Group** with least-privilege ingress rules
- **EC2 Instance** with NO IAM instance profile
- **Elastic IP** for stable DNS
- **Route53 Records** for all hostnames + NS delegation

### Bootstrap (user_data.sh.tftpl)
Idempotent bootstrap script that:
1. Updates system and installs packages (Ubuntu 24.04)
2. Creates site7 user and directories
3. Deploys application code from GitHub repo
4. Installs Python dependencies
5. Creates systemd service units with CAP_NET_BIND_SERVICE for DNS
6. Configures nginx with SNI routing
7. Provisions TLS (certbot certonly --standalone, 90s timeout, apex + malformed-http names only → self-signed SAN fallback)
8. Starts all services
9. Runs hardened health gate (all services + all ports)

## Resilience Test Mapping

Each endpoint maps to a specific resilience test in expected.yaml:

| Test ID | Endpoint(s) | Validation Method |
|---------|-------------|-------------------|
| SSRF-001 | /hostile/ssrf/fargate | Check 302 Location header contains 169.254.170.2 |
| SSRF-002 | /hostile/ssrf/imds | Check 302 Location header contains 169.254.169.254 |
| SSRF-003 | /hostile/ssrf/rfc1918 | Check 302 Location header contains 10.0.0.1 |
| SSRF-004 | /hostile/ssrf/localhost, ipv6-loopback, ipv6-private | Check 302 Location headers |
| SAFE-001 | /hostile/scope-escape | Check 302 Location to offscope subdomain |
| SAFE-002 | /hostile/redirect-loop/a,b,c | a→b→c→a cycle; scanner must cap redirect hops and not loop forever |
| SAFE-003 | /hostile/large-body, slow-body, gzip-bomb | Check Content-Length, timing, Content-Encoding |
| SAFE-004 | https://malformed-http.../malformed/chunked, banner | Verify no crash, defensive parsing |
| SAFE-004-TLS | https://malformed-tls.../ | Verify malformed TLS handled defensively |
| SAFE-005 | /hostile/read-only | Every method returns 200 and is recorded as an observation (no method is rejected) |
| SAFE-006 | /hostile/kill-test | Verify clean termination |
| SAFE-007 | rebind-test.paleon-lab-hostile.com | Query DNS twice, verify different IPs |

## Monitoring & Observability

### Logs
- **Systemd journal**: `journalctl -u paleon-site7 -f`
- **Nginx access/error**: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`
- **Bootstrap**: `/var/log/paleon-site7-bootstrap.log`
- **Observations**: in-memory `deque(maxlen=100)`, read via `GET /internal/site7-observation` (no log files)

### Health Checks
- `GET /health` → `{"status": "ok", "service": "paleon-site7"}`
- `GET /internal/site7-observation` → Recent observation logs

## Failure Scenarios & Mitigations

| Failure | Detection | Mitigation |
|---------|-----------|------------|
| Flask app crash | systemd restart (Restart=always) | Auto-restart within 5s |
| Malformed server crash | systemd restart | Auto-restart |
| DNS rebinding crash | systemd restart | Auto-restart |
| Nginx config error | nginx -t in bootstrap | Fail fast in bootstrap |
| Port conflict | ss -tlnp validation | Explicit port allocation |
| Certbot failure | Non-fatal, logged | Continue with self-signed |
| DNS not configured | host check | Skip HTTPS gracefully |

## Scaling Considerations

Current design is single-instance and intentionally stateless (no database, no external services, no shared cache). The following are options **only** if the target were ever repurposed for load — they are deliberately NOT part of Site 7 as shipped:
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

- Python services (Flask, malformed, DNS) run as the non-root `site7` user; Nginx runs as `www-data`
- No IAM instance profile
- Encrypted EBS root volume
- Security group allows only necessary ports
- No secrets in user_data or code
- TLS private key: 640 permissions (owner root, group site7-tls; both site7 and www-data are members)
- CAP_NET_BIND_SERVICE for DNS on port 53
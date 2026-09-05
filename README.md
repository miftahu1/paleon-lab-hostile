# PALEON TEST SITE 7 — Hostile Scanner Resilience Test Target

**Sector:** hostile-target  
**Domain:** paleon-lab-hostile.com  
**Description:** Adversarial target used to validate scanner safety and resilience

## What Site 7 Is

Site 7 is a **hostile test target** designed to validate the safety boundaries of the Paleon scanner runtime. It is a deliberately adversarial web application that attempts to induce the scanner to violate its trust boundaries through a variety of attack vectors including SSRF, scope escape, redirect loops, resource exhaustion, and malformed protocol handling.

## Why It Exists

The Paleon scanner must operate against arbitrary customer-controlled content. This target exists to:

1. **Validate scanner safety boundaries** — Confirm the scanner cannot be induced to access internal networks, credentials, or production infrastructure
2. **Test defensive mechanisms** — Verify rate limiting, connection timeouts, body size limits, and protocol parsing resilience
3. **Provide regression coverage** — Ensure fixes for boundary violations do not regress
4. **Demonstrate isolation** — Prove the target itself cannot reach real internal assets

## What It Tests

| Test Category | Test IDs | Description |
|---------------|----------|-------------|
| **SSRF (Server-Side Request Forgery)** | SSRF-001 through SSRF-006 | Attempts to induce scanner to make requests to internal metadata services, private IP ranges, localhost, and IPv6 private addresses |
| **Scope Escape** | SAFE-001 | Attempts to escape the scanner's allowed scope via redirects to off-scope host |
| **Redirect Loops** | SAFE-002 | Multi-step redirect chain to test loop detection |
| **Resource Exhaustion** | SAFE-003 | Large response bodies, slow streaming, gzip bombs |
| **Malformed Protocols** | SAFE-004 | Malformed chunked encoding, invalid HTTP status codes |
| **Passive Safety** | SAFE-005 | Read-only endpoint rejecting state-changing methods |
| **Termination Safety** | SAFE-006 | Clean termination on scan kill |
| **DNS Rebinding** | SAFE-007 | DNS rebinding attack simulation with TTL=0 |

## How It Is Isolated

**Site 7 runs on a dedicated, isolated instance with:**

- **No shared infrastructure** — Separate VM/container from any production or staging systems
- **No production connectivity** — Security groups deny all outbound traffic to private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16) and cloud metadata endpoints (169.254.169.254, 169.254.170.2)
- **Dedicated network interface** — Isolated VPC/subnet with no peering to production VPCs
- **No shared secrets** — No AWS credentials, database passwords, API keys, or service account tokens mounted
- **Localhost-only access paths** — Malformed server (port 5001), DNS rebind HTTP (port 5002), and DNS rebind UDP (port 8053) only reachable via SSRF redirect chain
- **Reverse proxy termination** — Nginx terminates TLS and proxies to Flask app (port 5000); Flask app not directly exposed

> ⚠️ **CRITICAL WARNING**
>
> **THIS TARGET IS DESIGNED TO ATTEMPT TO INDUCE THE SCANNER TO LEAVE ITS TRUST BOUNDARY.**
>
> Do not scan this target with production scanners. Do not deploy this target in any environment that has connectivity to production infrastructure. Do not reuse components from this target in production code.

## How to Validate Locally

```bash
# Start the full stack (requires Docker Compose)
cd C:/Users/mifta/Desktop/Paleon/Test Sites/hostile
docker compose up -d

# Verify services are healthy
docker compose ps

# Run local scanner against the target
# (Use your scanner's local test mode pointed at https://localhost)

# Check logs for expected test behaviors
docker compose logs -f flask-app
docker compose logs -f malformed-server
docker compose logs -f dns-rebind-server
```

## How to Reset

```bash
# Full reset — stops containers, removes volumes, rebuilds
docker compose down -v
docker compose build --no-cache
docker compose up -d

# Soft reset — restarts services only
docker compose restart

# Or use the provided reset script
./reset.sh
```

## How to Deploy

See [DEPLOYMENT.md](DEPLOYMENT.md) for full deployment instructions including:
- Terraform initialization and apply
- DNS verification
- Certificate provisioning
- Service verification
- Rollback procedures

## How to Verify

After deployment, verify each test endpoint responds as expected:

```bash
# SSRF tests (inspect Location headers - DO NOT FOLLOW)
curl -I http://site7.paleon-lab-hostile.com/hostile/ssrf/fargate
curl -I http://site7.paleon-lab-hostile.com/hostile/ssrf/imds
curl -I http://site7.paleon-lab-hostile.com/hostile/ssrf/rfc1918
curl -I http://site7.paleon-lab-hostile.com/hostile/ssrf/localhost
curl -I http://site7.paleon-lab-hostile.com/hostile/ssrf/ipv6-loopback
curl -I http://site7.paleon-lab-hostile.com/hostile/ssrf/ipv6-private

# Scope escape test
curl -I http://site7.paleon-lab-hostile.com/hostile/scope-escape

# Redirect loop test
curl -I http://site7.paleon-lab-hostile.com/hostile/redirect-loop

# Resource exhaustion tests
curl -I http://site7.paleon-lab-hostile.com/hostile/large-body
curl --max-time 10 http://site7.paleon-lab-hostile.com/hostile/slow-body
curl -I http://site7.paleon-lab-hostile.com/hostile/gzip-bomb

# Malformed protocol tests
curl -I http://site7.paleon-lab-hostile.com/hostile/malformed/chunked
curl -I http://site7.paleon-lab-hostile.com/hostile/malformed/banner

# Passive safety test
curl http://site7.paleon-lab-hostile.com/hostile/read-only
curl -X POST http://site7.paleon-lab-hostile.com/hostile/read-only  # Should return 405

# DNS rebinding test
dig @<public-ip> -p 8053 rebind-test.paleon-lab-hostile.com
dig @<public-ip> -p 8053 rebind-test.paleon-lab-hostile.com  # Should return different IP
```

## What NOT To Do

| Action | Reason |
|--------|--------|
| Deploy to production VPC | Target attempts SSRF to metadata services |
| Share infrastructure with production | Noisy neighbor risk; isolation violation |
| Mount production credentials | Target is designed to extract them via SSRF |
| Scan with production scanner without isolation | Scanner may be induced to scan internal assets |
| Modify security groups to allow outbound | Defeats the isolation model |
| Run malformed server on 0.0.0.0 with external access | Exposes protocol fuzzing to network |
| Disable Nginx rate limits | Removes protection against resource exhaustion |
| Follow SSRF redirect Location headers | Would connect to internal/metadata endpoints |

## Pass/Fail Criteria

| Criterion | Pass | Fail |
|-----------|------|------|
| **SSRF-001** Fargate metadata access | Scanner blocks/times out; no response from 169.254.170.2 | Scanner returns metadata content |
| **SSRF-002** EC2 IMDS access | Scanner blocks connection to 169.254.169.254 | Scanner returns metadata content |
| **SSRF-003** Private IP access | Scanner blocks connection to RFC1918 addresses | Scanner returns content from private IP |
| **SSRF-004** Localhost access (IPv4) | Scanner blocks connection to 127.0.0.1 | Scanner returns content from localhost |
| **SSRF-004** IPv6 loopback access | Scanner blocks connection to [::1] | Scanner returns content from IPv6 loopback |
| **SSRF-004** IPv6 ULA access | Scanner blocks connection to fc00::/7 | Scanner returns content from IPv6 ULA |
| **SAFE-001** Scope escape | Scanner enforces scope; doesn't follow off-scope redirect | Scanner follows redirect to offscope.paleon-lab-hostile.com |
| **SAFE-002** Redirect loop | Scanner detects loop within configured max hops | Scanner loops indefinitely or crashes |
| **SAFE-003** Large body | Scanner enforces body size limit; streams or truncates | Scanner OOMs or stores unbounded body |
| **SAFE-003** Slow body | Scanner enforces read timeout; cancels slow stream | Scanner hangs indefinitely |
| **SAFE-003** Gzip bomb | Scanner enforces decompression size limit | Scanner decompresses fully; OOM or disk exhaustion |
| **SAFE-004** Malformed chunked | Scanner rejects malformed chunked gracefully | Scanner crashes, hangs, or accepts invalid encoding |
| **SAFE-004** Malformed banner | Scanner rejects invalid status code gracefully | Scanner crashes, hangs, or accepts invalid status |
| **SAFE-005** Passive safety | Scanner only uses GET; no state-changing requests | Scanner sends POST/PUT/DELETE to read-only endpoint |
| **SAFE-006** Termination safety | Scanner handles SIGTERM cleanly; no orphan processes | Scanner leaves orphan processes on kill |
| **SAFE-007** DNS rebinding | Scanner re-validates DNS on reconnect; refuses private IP | Scanner connects to private IP after rebinding |

## Test ID Reference

| Test ID | Category | Endpoint | Stimulus |
|---------|----------|----------|----------|
| SSRF-001 | SSRF | `/hostile/ssrf/fargate` | HTTP 302 redirect to 169.254.170.2/v2/credentials |
| SSRF-002 | SSRF | `/hostile/ssrf/imds` | HTTP 302 redirect to 169.254.169.254/latest/meta-data/ |
| SSRF-003 | SSRF | `/hostile/ssrf/rfc1918` | HTTP 302 redirect to 10.0.0.1/admin |
| SSRF-004 | SSRF | `/hostile/ssrf/localhost` | HTTP 302 redirect to 127.0.0.1:8080/internal |
| SSRF-004 | SSRF | `/hostile/ssrf/ipv6-loopback` | HTTP 302 redirect to [::1]:8080/internal |
| SSRF-004 | SSRF | `/hostile/ssrf/ipv6-private` | HTTP 302 redirect to [fc00::1]/internal |
| SAFE-001 | Scope Escape | `/hostile/scope-escape` | HTTP 302 redirect to https://offscope.paleon-lab-hostile.com/ |
| SAFE-002 | Redirect Loop | `/hostile/redirect-loop` | 5-step redirect chain (steps 1-4: 302, step 5: 200) |
| SAFE-003 | Resource Exhaustion | `/hostile/large-body` | 15MB streaming response (Content-Length: 15728640) |
| SAFE-003 | Resource Exhaustion | `/hostile/slow-body` | 50 chunks over ~5 seconds (drip feed) |
| SAFE-003 | Resource Exhaustion | `/hostile/gzip-bomb` | Gzip compressed ~1KB expanding to 100MB (Content-Encoding: gzip) |
| SAFE-004 | Malformed Protocol | `/hostile/malformed/chunked` | Malformed chunked encoding (invalid hex size "GARBAGE") |
| SAFE-004 | Malformed Protocol | `/hostile/malformed/banner` | Invalid HTTP status code 999 |
| SAFE-005 | Passive Safety | `/hostile/read-only` | JSON response, rejects non-GET methods with 405 |
| SAFE-006 | Termination Safety | `/hostile/kill-test` | Simple JSON endpoint for kill testing |
| SAFE-007 | DNS Rebinding | `rebind-test.paleon-lab-hostile.com:8053` | UDP DNS: Query 1 returns 203.0.113.42, Query 2+ returns 10.0.0.50, TTL=0 |

---

**Document Version:** 1.0  
**Last Updated:** 2026-09-04  
**Maintained By:** Paleon Test Infrastructure Team
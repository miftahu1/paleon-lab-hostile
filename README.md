# PALEON TEST SITE 7 — Hostile Scanner Resilience Test Target

**Sector:** hostile-target  
**Domain:** paleon-lab-hostile.com  
**Description:** Adversarial target used to validate scanner safety and resilience

## What Site 7 Is

Site 7 is a **hostile test target** designed to validate the safety boundaries of the Paleon scanner runtime. It is a deliberately adversarial web application that attempts to induce the scanner to violate its trust boundaries through a variety of stimuli including SSRF redirect bait, scope escape, redirect loops, resource exhaustion, malformed HTTP/TLS, and DNS rebinding.

The target only **emits** hostile stimuli (redirect `Location` headers, oversized/slow/compressed bodies, malformed protocol bytes, and rebinding DNS answers). It never performs outbound requests, never authenticates, never touches credentials, and never reaches any real internal asset. Everything a scanner might be tempted to follow is bait that the target itself refuses to touch.

## Why It Exists

The Paleon scanner must operate against arbitrary customer-controlled content. This target exists to:

1. **Validate scanner safety boundaries** — Confirm the scanner cannot be induced to access internal networks, credentials, or production infrastructure
2. **Test defensive mechanisms** — Verify connection timeouts, body-size limits, decompression limits, and protocol-parsing resilience
3. **Provide regression coverage** — Ensure fixes for boundary violations do not regress
4. **Demonstrate isolation** — Prove the target itself cannot reach real internal assets

## What It Tests

| Test Category | Test IDs | Description |
|---------------|----------|-------------|
| **SSRF (Server-Side Request Forgery)** | SSRF-001 through SSRF-004 | Redirect bait toward cloud metadata services, RFC1918 ranges, localhost, and IPv6 loopback/ULA |
| **Scope Escape** | SAFE-001 | Redirect to an off-scope host |
| **Redirect Loops** | SAFE-002 | Three-cycle redirect chain (`a → b → c → a`) plus a self-loop |
| **Resource Exhaustion** | SAFE-003 | Large streamed body, slow drip body, gzip bomb |
| **Malformed HTTP** | SAFE-004 | Invalid chunked encoding and control-byte / length-mismatch headers, over real TLS |
| **Malformed TLS** | SAFE-004-TLS | Garbled TLS ServerHello that never completes a handshake |
| **Passive Safety** | SAFE-005 | Read-only observer endpoint that records the method used |
| **Termination Safety** | SAFE-006 | Connection held open for 15 s to test clean scan termination |
| **DNS Rebinding** | SAFE-007 | First DNS answer public, subsequent answers private, TTL=0 |

## Architecture at a Glance

| Layer | Detail |
|-------|--------|
| **Compute** | Single EC2 instance, Ubuntu 24.04 LTS, default VPC, `t3.micro` (configurable), IMDSv2 required, **no IAM instance profile** |
| **Public ports** | 22 (admin CIDR only), 53 TCP+UDP, 80, 443 |
| **Port 80** | `301` redirect to HTTPS |
| **Port 443** | Nginx `stream` + `ssl_preread` SNI dispatch (see below) |
| **Internal (localhost only)** | Flask `127.0.0.1:5000`, Nginx HTTPS termination `127.0.0.1:8443`, malformed TLS `127.0.0.1:9998`, malformed HTTP `127.0.0.1:9999` |
| **DNS** | Authoritative daemon on `:53` for `rebind-test.paleon-lab-hostile.com`, delegated by an `NS` record to `ns1.paleon-lab-hostile.com` (→ the instance EIP) |
| **Observations** | In-memory, bounded `deque(maxlen=100)`; read at `/internal/site7-observation` (localhost only). No on-disk observation logs. |

SNI routing on 443:

| SNI hostname | Backend | Behavior |
|--------------|---------|----------|
| `malformed-tls.paleon-lab-hostile.com` | `127.0.0.1:9998` | Raw TCP; emits a garbled ServerHello; TLS never completes |
| `malformed-http.paleon-lab-hostile.com` | `127.0.0.1:9999` | Completes a real TLS handshake, then emits malformed HTTP |
| anything else (default) | `127.0.0.1:8443` → Flask `5000` | Normal HTTPS termination to the Flask app |

## How It Is Isolated

**Site 7 runs on a standalone, minimally-privileged instance with:**

- **No shared infrastructure** — Dedicated EC2 instance, no shared resources with other Paleon sites
- **No AWS credentials** — No IAM instance profile is attached, and IMDSv2 is required, so no role credentials exist to steal
- **On-host egress isolation** — The unprivileged `site7` service user is blocked by host `iptables`/`ip6tables` owner rules from reaching RFC1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and IPv6 ULA/link-local (`fc00::/7`, `fe80::/10`). These rules are reinstalled on every boot by a `systemd` oneshot ordered before networking, so the isolation **persists across reboot**.
- **Application makes no outbound calls** — Defense in depth: the app code never opens an outbound socket. SSRF vectors are `Location` headers only; the target never follows them.
- **Localhost-only backends** — Flask (5000), Nginx termination (8443), and the malformed servers (9998/9999) bind `127.0.0.1` and are reachable only through the Nginx SNI router on 443.

> ⚠️ **CRITICAL WARNING**
>
> **THIS TARGET IS DESIGNED TO ATTEMPT TO INDUCE THE SCANNER TO LEAVE ITS TRUST BOUNDARY.**
>
> Do not scan this target with production scanners. Do not deploy this target in any environment that has connectivity to production infrastructure. Do not reuse components from this target in production code.

## How to Run Locally

There is no container stack; the application is three plain Python services fronted by Nginx. For a quick local check of the Flask app alone:

```bash
cd paleon-lab-hostile
python3 -m pip install -r requirements.txt
python3 app/app.py   # binds 127.0.0.1:5000
```

The malformed server and DNS server require a TLS key pair and privileged port 53 respectively, and are intended to run under `systemd` on the deployed instance (see [DEPLOYMENT.md](DEPLOYMENT.md)). To statically validate the repository without any host:

```bash
./validate.sh
```

## How to Reset

On the deployed instance, `reset.sh` restarts the services and restores the DNS-rebinding state to its initial (public-first) condition. In-memory observations are discarded automatically when the Flask service restarts.

```bash
sudo ./reset.sh
```

## How to Deploy

See [DEPLOYMENT.md](DEPLOYMENT.md) for full deployment instructions including:
- Terraform initialization and apply
- DNS delegation verification
- Certificate provisioning
- Service verification
- Rollback procedures

## How to Verify

After deployment, verify each test endpoint responds as expected. Inspect redirect `Location` headers — **do not follow them.** Replace `<eip>` with the instance Elastic IP.

```bash
# SSRF redirect bait (inspect Location headers - DO NOT FOLLOW)
curl -sI https://paleon-lab-hostile.com/hostile/ssrf/fargate
curl -sI https://paleon-lab-hostile.com/hostile/ssrf/fargate-relative
curl -sI https://paleon-lab-hostile.com/hostile/ssrf/imds
curl -sI "https://paleon-lab-hostile.com/hostile/ssrf/rfc1918?target=10"
curl -sI https://paleon-lab-hostile.com/hostile/ssrf/localhost
curl -sI https://paleon-lab-hostile.com/hostile/ssrf/ipv6-loopback
curl -sI https://paleon-lab-hostile.com/hostile/ssrf/ipv6-private

# Scope escape
curl -sI https://paleon-lab-hostile.com/hostile/scope-escape

# Redirect loop (3-cycle) and self-loop
curl -sI https://paleon-lab-hostile.com/hostile/redirect-loop
curl -sI https://paleon-lab-hostile.com/hostile/self-loop

# Resource exhaustion
curl -sI "https://paleon-lab-hostile.com/hostile/large-body?size_mb=10"
curl -s --max-time 10 "https://paleon-lab-hostile.com/hostile/slow-body?delay_ms=5000" -o /dev/null
curl -sI https://paleon-lab-hostile.com/hostile/gzip-bomb

# Malformed HTTP (over real TLS, via SNI subdomain) — raw bytes, do not parse as HTTP
curl -sk --resolve malformed-http.paleon-lab-hostile.com:443:<eip> \
     https://malformed-http.paleon-lab-hostile.com/malformed/chunked
curl -sk --resolve malformed-http.paleon-lab-hostile.com:443:<eip> \
     https://malformed-http.paleon-lab-hostile.com/malformed/banner

# Malformed TLS (handshake never completes) — expect a TLS error, not a page
openssl s_client -connect <eip>:443 -servername malformed-tls.paleon-lab-hostile.com </dev/null

# Passive safety (returns 200 and records the method used)
curl -s  https://paleon-lab-hostile.com/hostile/read-only
curl -sX POST https://paleon-lab-hostile.com/hostile/read-only

# DNS rebinding (delegated zone; first answer public, second answer private, TTL=0)
dig @<eip> rebind-test.paleon-lab-hostile.com A +short
dig @<eip> rebind-test.paleon-lab-hostile.com A +short   # subsequent answer -> 192.168.1.1
```

For an automated public-boundary check against a live instance, run `test_all_endpoints.py <eip>`.

## What NOT To Do

| Action | Reason |
|--------|--------|
| Deploy to a production VPC | Target emits SSRF bait toward metadata services |
| Share infrastructure with production | Noisy-neighbor risk; isolation violation |
| Mount production credentials | The target is bait; credentials must never be reachable |
| Scan with a production scanner without isolation | Scanner may be induced to scan internal assets |
| Attach an IAM instance profile | Would give the instance stealable role credentials |
| Weaken host egress rules or SG | Defeats the isolation model |
| Bind the malformed/DNS servers to `0.0.0.0` beyond port 53 | Exposes protocol fuzzing to the network |
| Follow SSRF redirect `Location` headers | Would connect to internal/metadata endpoints |

## Pass/Fail Criteria

| Criterion | Pass | Fail |
|-----------|------|------|
| **SSRF-001** Fargate/ECS metadata bait | Scanner refuses to fetch `169.254.170.2` | Scanner returns metadata content |
| **SSRF-002** EC2 IMDS bait | Scanner refuses to fetch `169.254.169.254` | Scanner returns metadata content |
| **SSRF-003** RFC1918 bait | Scanner refuses to fetch RFC1918 addresses | Scanner returns content from a private IP |
| **SSRF-004** Localhost / IPv6 loopback / IPv6 ULA bait | Scanner refuses `127.0.0.1`, `[::1]`, `[fd00::1]` | Scanner returns content from any of them |
| **SAFE-001** Scope escape | Scanner enforces scope; ignores off-scope redirect | Scanner follows redirect to `offscope.paleon-lab-hostile.com` |
| **SAFE-002** Redirect loop | Scanner detects the loop within its max-hop budget | Scanner loops indefinitely or crashes |
| **SAFE-003** Large body | Scanner enforces a body-size limit | Scanner OOMs or stores an unbounded body |
| **SAFE-003** Slow body | Scanner enforces a read timeout | Scanner hangs indefinitely |
| **SAFE-003** Gzip bomb | Scanner enforces a decompression limit | Scanner decompresses fully; OOM |
| **SAFE-004** Malformed HTTP | Scanner rejects malformed HTTP gracefully | Scanner crashes, hangs, or accepts invalid framing |
| **SAFE-004-TLS** Malformed TLS | Scanner reports a TLS failure and moves on | Scanner crashes or hangs on the bad handshake |
| **SAFE-005** Passive safety | Scanner uses only safe methods | Scanner sends state-changing methods to the observer |
| **SAFE-006** Termination safety | Scanner cancels the held connection cleanly | Scanner hangs or leaves orphan processes |
| **SAFE-007** DNS rebinding | Scanner re-validates DNS and refuses the private IP | Scanner connects to the private IP after rebinding |

## Test ID Reference

| Test ID | Category | Endpoint | Stimulus |
|---------|----------|----------|----------|
| SSRF-001 | SSRF | `/hostile/ssrf/fargate` | `302` → `http://169.254.170.2/v2/credentials/TEST_ONLY` |
| SSRF-001 | SSRF | `/hostile/ssrf/fargate-relative` | `302` → `http://169.254.170.2/v2/credentials/test-site7` |
| SSRF-002 | SSRF | `/hostile/ssrf/imds` | `302` → `http://169.254.169.254/latest/meta-data/` |
| SSRF-003 | SSRF | `/hostile/ssrf/rfc1918?target=10\|172\|192` | `302` → `http://10.0.0.1/` (or `172.16.0.1/`, `192.168.0.1/`) |
| SSRF-004 | SSRF | `/hostile/ssrf/localhost` | `302` → `http://127.0.0.1/` |
| SSRF-004 | SSRF | `/hostile/ssrf/ipv6-loopback` | `302` → `http://[::1]/` |
| SSRF-004 | SSRF | `/hostile/ssrf/ipv6-private` | `302` → `http://[fd00::1]/` |
| SAFE-001 | Scope Escape | `/hostile/scope-escape` | `302` → `https://offscope.paleon-lab-hostile.com/landing` |
| SAFE-002 | Redirect Loop | `/hostile/redirect-loop` | `302` chain `a → b → c → a`; `/hostile/self-loop` → itself |
| SAFE-003 | Resource Exhaustion | `/hostile/large-body?size_mb=` | Streamed body, default 10 MB, max 20 MB (`Content-Length` set) |
| SAFE-003 | Resource Exhaustion | `/hostile/slow-body?delay_ms=` | 10 × 1 KB chunks spread over the delay (default 5000 ms, max 15000 ms) |
| SAFE-003 | Resource Exhaustion | `/hostile/gzip-bomb` | Valid gzip, ~10 KB compressed → 10 MB decompressed (`Content-Encoding: gzip`) |
| SAFE-004 | Malformed HTTP | `https://malformed-http.paleon-lab-hostile.com/malformed/chunked` | `Transfer-Encoding: chunked` with an invalid chunk-size token `GARBAGE` |
| SAFE-004 | Malformed HTTP | `https://malformed-http.paleon-lab-hostile.com/malformed/banner` | Control bytes in a header value + `Content-Length` shorter than the body |
| SAFE-004-TLS | Malformed TLS | `https://malformed-tls.paleon-lab-hostile.com/` | Garbled TLS ServerHello; handshake never completes |
| SAFE-005 | Passive Safety | `/hostile/read-only` | Any method → `200`; records the method/path/headers as an observation |
| SAFE-006 | Termination Safety | `/hostile/kill-test` | Streams, holds the connection open for 15 s, then closes |
| SAFE-007 | DNS Rebinding | `rebind-test.paleon-lab-hostile.com` (`:53`) | Query #1 → instance EIP; query #2+ → `192.168.1.1`; TTL=0 |

---

**Document Version:** 2.0  
**Last Updated:** 2026-09-07  
**Maintained By:** Paleon Test Infrastructure Team

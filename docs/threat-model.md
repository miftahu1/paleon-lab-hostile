# PALEON TEST SITE 7 — Threat Model

## Executive Summary

This document describes the threat model for PALEON TEST SITE 7, a deliberately adversarial test target designed to validate the safety boundaries of the Paleon scanner runtime. The threat model follows a structured approach: identifying the attacker, the assets being protected, high-value safety properties, and assumptions.

---

## 1. Attacker

**Actor**: Customer-controlled hostile website (Site 7 itself)

**Capabilities**:
- Controls all HTTP responses served by the Site 7 application
- Controls DNS records for `paleon-lab-hostile.com` and subdomains
- Can return arbitrary HTTP status codes, headers, and response bodies
- Can serve malformed protocol data (invalid chunked encoding, junk banners)
- Can return redirects to any destination (internal IPs, metadata services, localhost, off-scope domains)
- Can create DNS rebinding scenarios (TTL=0, changing A records)
- Can stream arbitrarily large or slow response bodies
- Can serve compressed payloads with high expansion ratios
- Can hold connections open indefinitely

**Limitations** (by design):
- ❌ Cannot make outbound network connections (no `requests.get`, `urllib`, `httpx`, `socket.connect`)
- ❌ Cannot access AWS metadata services (169.254.169.254, 169.254.170.2)
- ❌ Cannot read environment variables containing secrets
- ❌ Cannot execute arbitrary shell commands
- ❌ Cannot access filesystem beyond `/var/lib/site7` (DNS rebind state only) and `/tmp`
- ❌ Cannot proxy attacker requests into internal networks
- ❌ Cannot relay credentials
- ❌ Cannot scan internal networks
- ❌ Cannot perform SSRF itself — only *induces* the scanner to do so

**Motivation**: The attacker *is* the test target. Its purpose is to attempt to induce the scanner to violate safety boundaries. It is not a "real" attacker in the traditional sense — it is a controlled adversarial environment.

---

## 2. Asset Being Protected

**Primary Asset**: **Paleon Scanner Runtime**

The scanner is the system under test. The safety properties of the scanner runtime are what Site 7 validates.

**Scanner Characteristics**:
- Non-intrusive external scanner
- Performs HTTP/TLS/DNS/TCP-connect checks
- Must operate against arbitrary customer content
- Runs in a controlled environment (not on customer infrastructure)
- Must never: access credentials, scan internal networks, perform destructive actions, crash, hang indefinitely

---

## 3. High-Value Safety Properties

| Property | Description | Test IDs |
|----------|-------------|----------|
| **No Credential Access** | Scanner never obtains AWS credentials, IAM tokens, database passwords, API keys, or any secret material | SSRF-001, SSRF-002, SSRF-004, SAFE-007 |
| **No Private Network Access** | Scanner never connects to RFC1918 addresses (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16), link-local (169.254.0.0/16), loopback (127.0.0.0/8, ::1), or IPv6 ULA (fd00::/8) | SSRF-003, SSRF-004 |
| **No Scope Escape** | Scanner never follows redirects or makes requests to domains outside its authorized scope (paleon-lab-hostile.com) | SAFE-001 |
| **No Destructive Requests** | Scanner never performs state-changing HTTP methods (POST, PUT, PATCH, DELETE, form submissions, credential submissions) | SAFE-005 |
| **No Resource Runaway** | Scanner enforces limits on response body size, read duration, decompression size, and connection count | SAFE-003 |
| **No Crash** | Scanner handles malformed protocols gracefully; never crashes, segfaults, or panics | SAFE-004 |
| **No Persistent Orphan Processes** | Scanner cleanup is complete on termination; no child processes, open file descriptors, or connections remain | SAFE-006 |
| **No Uncontrolled Outbound Connections** | Scanner only makes connections to explicitly authorized targets; all connections are tracked and bounded | SSRF-001 through SSRF-004, SAFE-001, SAFE-007 |

---

## 4. Assumptions

| # | Assumption | Justification |
|---|------------|---------------|
| A1 | Scanner is non-intrusive (read-only by design) | Core requirement of Paleon scanner |
| A2 | Scanner performs HTTP, TLS, DNS, and TCP connect checks | Documented scanner capabilities |
| A3 | Scanner must operate against arbitrary customer content | Production requirement |
| A4 | Scanner has configurable limits (redirects, body size, timeouts) | Standard scanner features |
| A5 | Scanner re-validates DNS on reconnect (not just on first resolve) | Security best practice for rebinding |
| A6 | Scanner runs in isolated environment (no production connectivity) | Operational requirement |
| A7 | Site 7 is deployed in complete isolation (dedicated instance, no shared VPC, no IAM role) | Deployment architecture |
| A8 | DNS for rebind-test hostname is controlled by lab | Infrastructure design |
| A9 | Off-scope domain resolves to same server but is logically separate | Test design |
| A10 | No real credentials exist anywhere in the Site 7 deployment | Security by design |

---

## 5. Trust Boundaries

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        TRUSTED: PALEON SCANNER                          │
│  - Scanner runtime, policies, limits, logging                           │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      TRUST BOUNDARY: NETWORK                            │
│  - HTTPS/TLS (ports 80/443)                                             │
│  - DNS queries (port 53 TCP/UDP) — rebind-test is authoritative DNS    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    UNTRUSTED: SITE 7 HOSTILE TARGET                     │
│  - Flask application (port 5000 behind Nginx)                           │
│  - Malformed TLS server (port 9998, 127.0.0.1 only)                     │
│  - Malformed HTTP server (port 9999, 127.0.0.1 only)                    │
│  - DNS rebind server (port 53 TCP/UDP, 0.0.0.0 — public authoritative)  │
│  - All responses are adversarial by design                              │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
           ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
           │ 169.254.x.x  │ │ RFC1918 IPs  │ │ offscope.    │
           │ (metadata)   │ │ (10/172/192) │ │ paleon...    │
           └──────────────┘ └──────────────┘ └──────────────┘
           BLOCKED        BLOCKED         OUT OF SCOPE
           BY SCANNER     BY SCANNER      (lab-owned)
```

**Trust Boundary Enforcement Points**:
1. **Scanner URL validation** — Before following any redirect or making any connection
2. **Scanner DNS pinning** — Resolve once, validate, re-validate on reconnect
3. **Scanner redirect counting** — Hard limit on redirect hops
4. **Scanner body size limits** — Streaming with hard ceiling
5. **Scanner timeout enforcement** — Per-connection and global budgets

---

## 6. Attack Surfaces

| Surface | Description | Mitigation |
|---------|-------------|------------|
| HTTP Redirects | 3xx responses with Location headers to prohibited destinations | URL validation, scope enforcement, private IP blocklist |
| DNS Rebinding | TTL=0, changing A records from public → private (authoritative DNS on port 53) | DNS pinning, re-validation on reconnect |
| Response Body Size | Streaming large or infinite bodies | Body size ceiling, streaming parse |
| Response Duration | Slowloris-style slow streaming | Read timeout, global time budget |
| Decompression | Gzip bombs (high ratio) | Decompression ceiling, streaming decompress |
| Malformed Protocol | Invalid chunked, junk banners, bad TLS | Defensive parsing, fail-safe defaults |
| HTTP Methods | POST, PUT, DELETE, etc. on read-only endpoints | Method allowlist (GET, HEAD only) |
| Connection Hold | Long-lived connections, slowloris | Connection timeout, max connections |

---

## 7. Out of Scope

The following are **explicitly out of scope** for Site 7:

- **Real vulnerability exploitation** — Site 7 does not exploit; it only tests scanner resilience
- **Production credential theft** — No credentials exist on Site 7
- **Internal network pivoting** — Site 7 has no connectivity to internal networks
- **Scanner authentication bypass** — Scanner has no authentication (it's a scanner)
- **Data exfiltration from Site 7** — Site 7 has no data to exfiltrate
- **Denial of service against Site 7** — Site 7 is the adversary, not the victim
- **Supply chain attacks** — No dependencies on external services
- **Physical security** — Cloud-hosted, out of scope

---

## 8. Residual Risk

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Scanner has unknown vulnerability allowing SSRF | Low | Critical | Defense in depth: multiple validation layers |
| DNS rebinding works due to scanner DNS caching bug | Medium | High | Test with TTL=0; verify re-validation |
| Resource exhaustion bypasses limits | Low | High | Multiple independent limits (size, time, count) |
| Malformed protocol causes scanner crash | Low | Medium | Fuzz testing; defensive parsing |
| Off-scope host accidentally receives scanner requests | Low | Medium | Scope enforcement at DNS and HTTP layer |

---

## 9. Verification Strategy

Each safety property is validated by a specific test:

| Safety Property | Test ID | Verification Method |
|-----------------|---------|---------------------|
| No credential access | SSRF-001, SSRF-002 | Verify scanner never connects to 169.254.x.x |
| No private network access | SSRF-003, SSRF-004 | Verify scanner never connects to RFC1918/loopback |
| No scope escape | SAFE-001 | Verify off-scope host receives zero requests |
| No destructive requests | SAFE-005 | Verify only GET/HEAD observed at read-only endpoint |
| No resource runaway | SAFE-003 | Verify scanner enforces size/time limits |
| No crash | SAFE-004 | Verify scanner completes scan after malformed responses |
| No orphan processes | SAFE-006 | Verify clean process state after kill |
| No uncontrolled outbound | SAFE-007 | Verify scanner re-validates DNS and refuses private |

---

## 10. Conclusion

Site 7 is a **safety boundary test**, not a vulnerability detection target. Its purpose is to provide observed, evidence-based confirmation that the Paleon scanner maintains its trust boundaries when faced with deliberately adversarial input. No absolute safety claims are made — only specific, observed behaviors under controlled test conditions.
# PALEON TEST SITE 7 — Test Matrix

This document defines the complete test matrix for scanner resilience validation.

## Overview

Each test case specifies:
- **Endpoint**: The exact URL or hostname to test
- **Stimulus**: What the test endpoint returns to the scanner
- **Expected Scanner Behavior**: What the scanner should do (evidence-based)
- **Expected Target Observation**: What the test harness will log
- **Evidence to Collect**: Data proving the test was executed and result
- **Severity**: Impact if the scanner fails this test
- **Blocker**: Whether a failure blocks deployment
- **Claim Strength**: Nature of the claim (observed only, not absolute)

## Test Matrix

### SSRF-001: Fargate Metadata Redirect

| Field | Value |
|-------|-------|
| **Test ID** | SSRF-001 |
| **Category** | ssrf_safety |
| **Endpoint** | `https://paleon-lab-hostile.com/hostile/ssrf/fargate` |
| **Stimulus** | HTTP 302 redirect to `http://169.254.170.2/v2/credentials/TEST_ONLY` |
| **Expected Scanner Behavior** | Scanner should detect the redirect destination is a link-local address (169.254.x.x) and refuse to follow it |
| **Expected Target Observation** | Redirect logged with destination `169.254.170.2`; no connection to that address |
| **Evidence to Collect** | Request logs showing redirect followed (or not), Location header value, scanner's reason for stopping |
| **Severity** | CRITICAL |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner refused redirect to link-local credentials endpoint |

### SSRF-002: EC2 IMDS Redirect

| Field | Value |
|-------|-------|
| **Test ID** | SSRF-002 |
| **Category** | ssrf_safety |
| **Endpoint** | `https://paleon-lab-hostile.com/hostile/ssrf/imds` |
| **Stimulus** | HTTP 302 redirect to `http://169.254.169.254/latest/meta-data/` |
| **Expected Scanner Behavior** | Scanner should detect IMDS endpoint and refuse to follow redirect |
| **Expected Target Observation** | Redirect logged with destination `169.254.169.254`; no connection attempt |
| **Evidence to Collect** | Request logs, Location header, scanner decision log |
| **Severity** | CRITICAL |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner refused redirect to EC2 metadata endpoint |

### SSRF-003: RFC1918 Private Addresses

| Field | Value |
|-------|-------|
| **Test ID** | SSRF-003 |
| **Category** | ssrf_safety |
| **Endpoints** | `https://paleon-lab-hostile.com/hostile/ssrf/rfc1918?target=10` (→ 10.0.0.1), `?target=172` (→ 172.16.0.1), `?target=192` (→ 192.168.0.1) |
| **Stimulus** | HTTP 302 redirect to RFC1918 address based on query parameter |
| **Expected Scanner Behavior** | Scanner should detect private IP ranges and refuse to follow any redirect to 10.x.x.x, 172.16-31.x.x, or 192.168.x.x |
| **Expected Target Observation** | All three variants logged; no connection attempts to private addresses |
| **Evidence to Collect** | Logs for each target variant, Location headers, scanner policy violations |
| **Severity** | CRITICAL |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner refused redirects to private RFC1918 addresses |

### SSRF-004: Loopback and IPv6 Private Redirects

| Field | Value |
|-------|-------|
| **Test ID** | SSRF-004 |
| **Category** | ssrf_safety |
| **Endpoints** | `https://paleon-lab-hostile.com/hostile/ssrf/localhost` (→ 127.0.0.1), `/hostile/ssrf/ipv6-loopback` (→ [::1]), `/hostile/ssrf/ipv6-private` (→ [fd00::1]) |
| **Stimulus** | HTTP 302 redirects to localhost and IPv6 addresses |
| **Expected Scanner Behavior** | Scanner should refuse all redirects to loopback (127.x.x.x, ::1) and IPv6 private (fd00::/8) |
| **Expected Target Observation** | Three redirect logs; no connections to prohibited addresses |
| **Evidence to Collect** | Location headers for each endpoint, scanner policy decisions |
| **Severity** | CRITICAL |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner refused redirects to loopback and IPv6 private addresses |

### SAFE-001: Scope Escape via Redirect

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-001 |
| **Category** | scope_safety |
| **Endpoint** | `https://paleon-lab-hostile.com/hostile/scope-escape` |
| **Stimulus** | HTTP 302 redirect to `https://offscope.paleon-lab-hostile.com/landing` |
| **Expected Scanner Behavior** | Scanner should recognize `offscope.paleon-lab-hostile.com` is outside authorized scope and refuse to follow |
| **Expected Target Observation** | Redirect logged; off-scope host receives zero requests (confirmed by access logs or network monitor) |
| **Evidence to Collect** | Location header value, off-scope server access logs (must be empty), scanner scope enforcement log |
| **Severity** | HIGH |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner refused off-scope redirect; off-scope host received no requests |

### SAFE-002: Redirect Loop Detection

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-002 |
| **Category** | redirect_safety |
| **Endpoints** | `/hostile/redirect-loop/a` → b → c → a, `/hostile/self-loop` (→ itself) |
| **Stimulus** | 3-cycle redirect loop and self-referential redirect |
| **Expected Scanner Behavior** | Scanner should detect loop within configured limit (e.g., 5-10 redirects) and terminate gracefully |
| **Expected Target Observation** | Multiple redirect logs showing cycle; no unbounded following |
| **Evidence to Collect** | Sequence of redirect logs, scanner's redirect count, termination reason |
| **Severity** | HIGH |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner terminated redirect following within configured limit |

### SAFE-003: Resource Exhaustion Resistance

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-003 |
| **Category** | resource_safety |
| **Endpoints** | `/hostile/large-body?size_mb=20`, `/hostile/slow-body?delay_ms=15000`, `/hostile/gzip-bomb` |
| **Stimulus** | Large streaming response, slow streaming response, decompression bomb |
| **Expected Scanner Behavior** | Scanner should enforce body size limit, read timeout, and decompression ceiling; no OOM or hang |
| **Expected Target Observation** | Streaming logs for each endpoint; no full payload allocated in RAM |
| **Evidence to Collect** | Request duration, bytes received, scanner resource usage, termination reason |
| **Severity** | HIGH |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner bounded response size and duration; no resource runaway |

### SAFE-004: Malformed Protocol Handling (HTTP)

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-004 |
| **Category** | parser_safety |
| **Endpoints** | `https://malformed-http.paleon-lab-hostile.com/malformed/chunked`, `https://malformed-http.paleon-lab-hostile.com/malformed/banner` |
| **Stimulus** | Invalid chunked encoding (GARBAGE chunk size), junk HTTP banner with control chars in header (`\x00\x01\x02\x03`) |
| **Expected Scanner Behavior** | Scanner should parse defensively; fail gracefully without crash; continue scan |
| **Expected Target Observation** | Connection logs showing malformed responses sent via malformed-http server on 9999 (via SNI on 443) |
| **Evidence to Collect** | Scanner crash log (must be empty), scan completion status, error handling behavior |
| **Severity** | HIGH |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner survived malformed HTTP responses without crash |

### SAFE-004-TLS: Malformed TLS Handling

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-004-TLS |
| **Category** | parser_safety |
| **Endpoint** | `https://malformed-tls.paleon-lab-hostile.com/` |
| **Stimulus** | Malformed TLS ServerHello with invalid version/random bytes (garbled handshake) |
| **Expected Scanner Behavior** | Scanner should detect invalid TLS handshake; fail certificate validation cleanly; no crash |
| **Expected Target Observation** | Connection logs showing garbled ServerHello sent via malformed-tls server on 9998 (via SNI on 443) |
| **Evidence to Collect** | Scanner crash log (must be empty), TLS error handling, scan completion status |
| **Severity** | HIGH |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner survived malformed TLS handshake without crash |

### SAFE-005: Passive Scanning Only (Read-Only)

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-005 |
| **Category** | passive_safety |
| **Endpoint** | `https://paleon-lab-hostile.com/hostile/read-only` (all HTTP methods) |
| **Stimulus** | Endpoint that logs all requests and returns 200 |
| **Expected Scanner Behavior** | Scanner should use only GET, HEAD, or explicitly documented passive methods; no POST, PUT, DELETE, PATCH, OPTIONS-with-body, or form submissions |
| **Expected Target Observation** | Request logs showing only safe methods; no state-changing methods observed |
| **Evidence to Collect** | List of observed HTTP methods, request bodies (must be empty), scanner documentation of allowed methods |
| **Severity** | HIGH |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: no state-changing HTTP requests observed during normal scan |

### SAFE-006: Clean Termination (Kill Test)

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-006 |
| **Category** | termination_safety |
| **Endpoint** | `https://paleon-lab-hostile.com/hostile/kill-test` |
| **Stimulus** | Connection held for 15 seconds |
| **Expected Scanner Behavior** | Scanner should terminate cleanly when operator kills scan; no orphan processes, no runaway connections |
| **Expected Target Observation** | Connection log showing 15s hold; no spawned processes from target |
| **Evidence to Collect** | Process list before/after kill (no orphan PIDs), connection count before/after, clean exit status |
| **Severity** | MEDIUM |
| **Blocker** | No |
| **Claim Strength** | Observed behavior: scanner terminated cleanly on kill signal |

### SAFE-007: DNS Rebinding Safety

| Field | Value |
|-------|-------|
| **Test ID** | SAFE-007 |
| **Category** | dns_rebinding_safety |
| **Target** | `rebind-test.paleon-lab-hostile.com` (DNS on port 53 TCP/UDP, authoritative on Site 7 EIP) |
| **Stimulus** | First DNS lookup returns Site 7 EIP (public); subsequent lookups return private IP (192.168.1.1) with TTL=0 |
| **Expected Scanner Behavior** | Scanner should re-validate DNS resolution on reconnect; detect rebinding; refuse connection to private address |
| **Expected Target Observation** | DNS query logs showing sequence (public → private); scanner refusing private address |
| **Evidence to Collect** | DNS server logs showing query sequence, scanner DNS resolution logs, scanner policy decision |
| **Severity** | CRITICAL |
| **Blocker** | Yes |
| **Claim Strength** | Observed behavior: scanner re-validated DNS and refused private address after rebinding |

## Must-Not-Flag Conditions

The scanner must NOT produce any of the following findings against Site 7:

| Condition | Reason |
|-----------|--------|
| `credential_acquired` | No real credentials exist on target |
| `internal_resource_access` | Target has no connectivity to internal resources |
| `off_scope_host_scanned` | Off-scope host is controlled by lab; zero requests expected |
| `destructive_request` | Target has no state to destroy; all endpoints are read-only or return data |
| `unbounded_redirect_following` | All redirects are bounded by scanner's redirect limit |
| `scanner_crash_as_success` | Crash is a failure, not a passing condition |
| `successful_private_connect` | No private addresses exist on target; only URLs are returned as redirect destinations |

## Evidence Collection Protocol

For each test execution:

1. **Before Test**: Record scanner state, process list, connection count
2. **During Test**: Collect:
   - Target server logs (structured JSON)
   - DNS server logs (if testing rebind)
   - Scanner decision logs (redirect followed, blocked, timeout, etc.)
   - Network captures (if needed for forensic analysis)
3. **After Test**: Record:
   - Scanner exit status
   - Orphan process check
   - Connection leak check
   - Final log state

## Severity Definitions

| Severity | Impact | Blocker? |
|----------|--------|----------|
| CRITICAL | Scanner can be induced to access credentials or private networks | Yes |
| HIGH | Scanner violates trust boundary or resource limits | Yes |
| MEDIUM | Scanner behavior is suboptimal but not dangerous | No |
| LOW | Minor observation, no safety impact | No |

## Claim Strength

All claims must be **evidence-based**:
- ✅ "Scanner refused redirect to 169.254.169.254"
- ✅ "No connection observed to private IP"
- ✅ "Scanner terminated within configured redirect limit"
- ❌ "Scanner is secure"
- ❌ "Scanner cannot be exploited"
- ❌ "Scanner is guaranteed safe"

Site 7 can only establish: observed behavior, specific test passed, no observed credential request, no observed connection to prohibited target, bounded behavior under this test.
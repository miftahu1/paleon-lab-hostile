# PALEON SITE 7 — API Reference

## Base URL
- **HTTP**: `http://paleon-lab-hostile.com` (via nginx on port 80)
- **HTTPS**: `https://paleon-lab-hostile.com` (via nginx on port 443, when TLS configured)
- **Direct Flask**: `http://127.0.0.1:5000` (internal, not publicly accessible)

## Endpoint Categories

### SSRF Safety Endpoints (Critical)

All SSRF endpoints return **HTTP 302** with a `Location` header pointing to a dangerous destination. Scanners MUST inspect the Location header but MUST NOT follow the redirect.

#### GET /hostile/ssrf/fargate
- **Test ID**: SSRF-001
- **Response**: 302 Found
- **Location**: `http://169.254.170.2/v2/credentials/TEST_ONLY`
- **Purpose**: Simulates redirect to AWS Fargate credentials endpoint

#### GET /hostile/ssrf/fargate-relative
- **Test ID**: SSRF-001
- **Response**: 302 Found
- **Location**: `http://169.254.170.2/v2/credentials/test-site7`
- **Purpose**: Simulates redirect to AWS Fargate credentials endpoint with test path

#### GET /hostile/ssrf/imds
- **Test ID**: SSRF-002
- **Response**: 302 Found
- **Location**: `http://169.254.169.254/latest/meta-data/`
- **Purpose**: Simulates redirect to EC2 Instance Metadata Service

#### GET /hostile/ssrf/rfc1918
- **Test ID**: SSRF-003
- **Response**: 302 Found
- **Location**: `http://10.0.0.1/` (or 172.16.0.1, 192.168.0.1 based on `target` param)
- **Parameters**: `target=10|172|192` (default: 10)
- **Purpose**: Simulates redirect to RFC1918 private address

#### GET /hostile/ssrf/localhost
- **Test ID**: SSRF-004
- **Response**: 302 Found
- **Location**: `http://127.0.0.1/`
- **Purpose**: Simulates redirect to IPv4 loopback

#### GET /hostile/ssrf/ipv6-loopback
- **Test ID**: SSRF-004
- **Response**: 302 Found
- **Location**: `http://[::1]/`
- **Purpose**: Simulates redirect to IPv6 loopback

#### GET /hostile/ssrf/ipv6-private
- **Test ID**: SSRF-004
- **Response**: 302 Found
- **Location**: `http://[fd00::1]/`
- **Purpose**: Simulates redirect to IPv6 ULA (Unique Local Address)

---

### Scope Safety Endpoint (High)

#### GET /hostile/scope-escape
- **Test ID**: SAFE-001
- **Response**: 302 Found
- **Location**: `https://offscope.paleon-lab-hostile.com/landing`
- **Purpose**: Tests that scanner does not follow redirects to off-scope hosts

---

### Redirect Safety Endpoint (High)

#### GET /hostile/redirect-loop/a
#### GET /hostile/redirect-loop/b
#### GET /hostile/redirect-loop/c
- **Test ID**: SAFE-002
- **Response**: 302 Found at every step, including `/redirect-loop/c`
- **Chain**: `/redirect-loop` → `/redirect-loop/a` → `/redirect-loop/b` → `/redirect-loop/c` → `/redirect-loop/a` (unbounded cycle; the target never self-terminates)
- **Purpose**: Tests that the scanner detects the cycle and stops within its own hop limit — the target does not break the loop for it

#### GET /hostile/self-loop
- **Response**: 302 Found to self
- **Purpose**: Self-referential redirect for loop detection

---

### Resource Safety Endpoints (High)

#### GET /hostile/large-body
- **Test ID**: SAFE-003
- **Response**: 200 OK
- **Content-Type**: `application/octet-stream`
- **Content-Length**: Variable (via `size_mb` parameter, default 10, max 20)
- **Streaming**: Body is generated and streamed server-side without buffering in RAM; a fixed `Content-Length` is declared (this endpoint is **not** `Transfer-Encoding: chunked`)
- **Purpose**: Tests response size bounding

#### GET /hostile/slow-body
- **Test ID**: SAFE-003
- **Response**: 200 OK
- **Content-Type**: `application/octet-stream`
- **Transfer-Encoding**: chunked (streamed; no `Content-Length`)
- **Duration**: Variable (via `delay_ms` parameter, default 5000, min 100, max 15000)
- **Purpose**: Tests response duration bounding

#### GET /hostile/gzip-bomb
- **Test ID**: SAFE-003
- **Response**: 200 OK
- **Content-Type**: `application/gzip`
- **Content-Encoding**: `gzip`
- **X-Decompressed-Size**: `10485760` (declared decompressed byte count)
- **Content-Length**: none — the compressed body (~10 KB) is streamed, so no `Content-Length` is sent
- **Uncompressed Size**: exactly 10485760 bytes (10 MiB)
- **Purpose**: Tests decompression ratio bounding

---

### Parser Safety Endpoints (High)

#### GET https://malformed-http.paleon-lab-hostile.com/malformed/chunked
- **Test ID**: SAFE-004
- **Response**: 200 OK (after valid TLS handshake)
- **Transfer-Encoding**: `chunked`
- **Body**: Valid chunk followed by invalid hex chunk size (`GARBAGE`), then proper terminator
- **Purpose**: Tests defensive parsing of malformed chunked responses

#### GET https://malformed-http.paleon-lab-hostile.com/malformed/banner
- **Test ID**: SAFE-004
- **Response**: 200 OK (after valid TLS handshake)
- **Headers**: Contains control characters (`\x00\x01\x02\x03`) in header value
- **Body**: `MALFORMED_HEADER`
- **Purpose**: Tests handling of control characters in HTTP headers

#### GET https://malformed-tls.paleon-lab-hostile.com/
- **Test ID**: SAFE-004-TLS
- **Response**: TLS handshake fails with malformed ServerHello
- **ServerHello**: Garbled payload with invalid version/random bytes
- **Purpose**: Tests defensive handling of malformed TLS handshake

---

### Passive Safety Endpoint (High)

#### GET /hostile/read-only
- **Test ID**: SAFE-005
- **Response**: 200 OK
- **Content-Type**: `text/plain`
- **Body**: `OK - Request observed and logged`
- **Methods**: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS (all logged; **every** method returns 200)
- **Purpose**: Verifies scanner makes no state-changing requests during passive scan

#### POST /hostile/read-only (and other methods)
- **Response**: 200 OK (but logged as observation)
- **Purpose**: Should be logged as passive safety observation if attempted

---

### Termination Safety Endpoint (Medium)

#### GET /hostile/kill-test
- **Test ID**: SAFE-006
- **Response**: 200 OK (streaming)
- **Content-Type**: `text/plain`
- **Behavior**: Holds connection for 15 seconds then closes
- **Purpose**: Tests scanner termination behavior

---

### DNS Rebinding Safety (Critical)

#### rebind-test.paleon-lab-hostile.com (DNS on port 53 UDP/TCP)
- **Test ID**: SAFE-007
- **First Query**: Returns A record = Site 7 EIP (public)
- **Subsequent Queries**: Returns A record `192.168.1.1` (private)
- **TTL**: 0 (no caching)
- **Flags**: AA=1 (authoritative), RA=0 (no recursion)
- **Purpose**: Tests that scanner re-validates DNS on reconnect and refuses private address after rebinding

---

### Internal Endpoints

#### GET /internal/site7-observation
- **Response**: 200 OK
- **Content-Type**: `application/json`
- **Body**: Observation logs (last 100 entries)
- **Access**: Localhost only (127.0.0.1, ::1)
- **Purpose**: Access observation logs for verification

```json
{
  "observations": [
    {
      "timestamp": "2026-09-04T12:00:00Z",
      "test_id": "ssrf_fargate",
      "method": "GET",
      "path": "/hostile/ssrf/fargate",
      "status": 302,
      "redirect_destination": "http://169.254.170.2/v2/credentials/TEST_ONLY",
      "body_size_bytes": 0,
      "off_scope_attempt": false
    }
  ]
}
```

#### GET /health
- **Response**: 200 OK
- **Content-Type**: `application/json`
- **Body**: `{"status": "ok", "service": "paleon-site7"}`
- **Purpose**: Health check endpoint

---

## Response Headers

### Standard Headers (All Endpoints)
- `Server`: nginx or Werkzeug
- `Date`: RFC 1123 date
- `Connection`: keep-alive

### Redirect Endpoints (302)
- `Location`: Target URL (dangerous destination)
- `Content-Type`: text/html (Flask default redirect page)

### Resource Endpoints
- `Content-Length`: Size in bytes (large-body)
- `Transfer-Encoding`: chunked (slow-body, gzip-bomb — both streamed without Content-Length)
- `Content-Encoding`: gzip (gzip-bomb)

### Malformed Endpoints (via SNI)
- `Transfer-Encoding`: chunked (malformed/chunked)
- `X-Control-Header`: Contains control chars (malformed/banner)

---

## Error Responses

| Status | Condition |
|--------|-----------|
| 403 | Internal endpoint accessed from non-localhost |
| 404 | Unknown endpoint |
| 405 | Method not allowed (rare - most endpoints accept all methods) |
| 500 | Internal server error (should not occur in normal operation) |
| 503 | Service unavailable (during restart) |

---

## Rate Limiting

No rate limiting is applied by the test target. Scanners should implement their own rate limiting.

---

## CORS

No CORS headers are set. Cross-origin requests from browsers will be blocked by browser policy.

---

## Versioning

No API versioning. Endpoints are stable for the test target lifetime.
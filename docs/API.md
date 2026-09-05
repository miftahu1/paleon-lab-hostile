# PALEON SITE 7 — API Reference

## Base URL
- **HTTP**: `http://paleon-lab-hostile.com` (via nginx on port 80)
- **HTTPS**: `https://paleon-lab-hostile.com` (via nginx on port 443, when configured)
- **Direct Flask**: `http://<host>:5000` (internal, not recommended for scanning)

## Endpoint Categories

### SSRF Safety Endpoints (Critical)

All SSRF endpoints return **HTTP 302** with a `Location` header pointing to a dangerous destination. Scanners MUST inspect the Location header but MUST NOT follow the redirect.

#### GET /hostile/ssrf/fargate
- **Test ID**: SSRF-001
- **Response**: 302 Found
- **Location**: `http://169.254.170.2/v2/credentials`
- **Purpose**: Simulates redirect to AWS Fargate credentials endpoint

#### GET /hostile/ssrf/imds
- **Test ID**: SSRF-002
- **Response**: 302 Found
- **Location**: `http://169.254.169.254/latest/meta-data/`
- **Purpose**: Simulates redirect to EC2 Instance Metadata Service

#### GET /hostile/ssrf/rfc1918
- **Test ID**: SSRF-003
- **Response**: 302 Found
- **Location**: `http://10.0.0.1/admin`
- **Purpose**: Simulates redirect to RFC1918 private address

#### GET /hostile/ssrf/localhost
- **Test ID**: SSRF-004
- **Response**: 302 Found
- **Location**: `http://127.0.0.1:8080/internal`
- **Purpose**: Simulates redirect to IPv4 loopback

#### GET /hostile/ssrf/ipv6-loopback
- **Test ID**: SSRF-004
- **Response**: 302 Found
- **Location**: `http://[::1]:8080/internal`
- **Purpose**: Simulates redirect to IPv6 loopback

#### GET /hostile/ssrf/ipv6-private
- **Test ID**: SSRF-004
- **Response**: 302 Found
- **Location**: `http://[fc00::1]/internal`
- **Purpose**: Simulates redirect to IPv6 ULA (Unique Local Address)

---

### Scope Safety Endpoint (High)

#### GET /hostile/scope-escape
- **Test ID**: SAFE-001
- **Response**: 302 Found
- **Location**: `https://offscope.paleon-lab-hostile.com/`
- **Purpose**: Tests that scanner does not follow redirects to off-scope hosts

---

### Redirect Safety Endpoint (High)

#### GET /hostile/redirect-loop
#### GET /hostile/redirect-loop/<step>
- **Test ID**: SAFE-002
- **Response**: 302 Found (steps 1-4), 200 OK (step 5)
- **Chain**: `/redirect-loop` → `/redirect-loop/2` → `/redirect-loop/3` → `/redirect-loop/4` → `/redirect-loop/5` (200)
- **Purpose**: Tests redirect loop detection and termination within configured limit

---

### Resource Safety Endpoints (High)

#### GET /hostile/large-body
- **Test ID**: SAFE-003
- **Response**: 200 OK
- **Content-Type**: `application/octet-stream`
- **Content-Length**: `15728640` (15 MB)
- **Transfer-Encoding**: chunked (streamed in 1MB chunks)
- **Purpose**: Tests response size bounding

#### GET /hostile/slow-body
- **Test ID**: SAFE-003
- **Response**: 200 OK
- **Content-Type**: `text/plain`
- **Transfer-Encoding**: chunked
- **Duration**: ~5 seconds (50 chunks × 100ms)
- **Purpose**: Tests response duration bounding

#### GET /hostile/gzip-bomb
- **Test ID**: SAFE-003
- **Response**: 200 OK
- **Content-Type**: `application/gzip`
- **Content-Encoding**: `gzip`
- **Content-Length**: ~1 KB (compressed)
- **Uncompressed Size**: 100 MB
- **Purpose**: Tests decompression ratio bounding

---

### Parser Safety Endpoints (High)

#### GET /hostile/malformed/chunked
- **Test ID**: SAFE-004
- **Response**: 200 OK
- **Transfer-Encoding**: `chunked`
- **Body**: Malformed chunked encoding with invalid hex chunk size (`GARBAGE`)
- **Purpose**: Tests defensive parsing of malformed chunked responses

#### GET /hostile/malformed/banner
- **Test ID**: SAFE-004
- **Response**: 999 (Invalid status code)
- **Content-Type**: `text/plain`
- **Body**: `Body content`
- **Purpose**: Tests handling of invalid HTTP status lines

---

### Additional Malformed Endpoints (Port 5001)

These endpoints are served by the malformed_server.py on port 5001:

| Endpoint | Description |
|----------|-------------|
| `/malformed/no-status` | Response missing status line |
| `/malformed/bad-header` | Header without colon separator |
| `/malformed/no-crlf` | Header missing CRLF termination |
| `/malformed/bad-chunk` | Invalid chunk size in chunked encoding |
| `/malformed/premature-close` | Connection closed before Content-Length fulfilled |
| `/malformed/null-bytes` | Null bytes in header values |

---

### Passive Safety Endpoint (High)

#### GET /hostile/read-only
- **Test ID**: SAFE-005
- **Response**: 200 OK
- **Content-Type**: `application/json`
- **Body**: `{"status": "ok", "message": "Read-only endpoint - no state changes", "test_id": "SAFE-005"}`
- **Methods**: GET only (POST/PUT/DELETE return 405)
- **Purpose**: Verifies scanner makes no state-changing requests during passive scan

#### POST /hostile/read-only
- **Response**: 405 Method Not Allowed
- **Purpose**: Should be logged as passive safety violation if attempted

---

### Termination Safety Endpoint (Medium)

#### GET /hostile/kill-test
- **Test ID**: SAFE-006
- **Response**: 200 OK
- **Content-Type**: `application/json`
- **Body**: `{"status": "ok", "message": "Kill test endpoint - scanner should handle termination cleanly", "test_id": "SAFE-006"}`
- **Purpose**: Endpoint for testing scanner termination behavior

---

### DNS Rebinding Safety (Critical)

#### rebind-test.paleon-lab-hostile.com (DNS on port 8053 UDP)
- **Test ID**: SAFE-007
- **First Query**: Returns A record `203.0.113.42` (public)
- **Subsequent Queries**: Returns A record `10.0.0.50` (private)
- **TTL**: 0 (no caching)
- **Purpose**: Tests that scanner re-validates DNS on reconnect and refuses private address after rebinding

#### GET http://rebind-test.paleon-lab-hostile.com:5002/rebind-test
- **Response**: 200 OK
- **Content-Type**: `application/json`
- **Body**: Includes current DNS state and query count
- **Purpose**: HTTP endpoint to verify rebinding state

---

### Internal Endpoints

#### GET /internal/site7-observation
- **Response**: 200 OK
- **Content-Type**: `application/json`
- **Body**: Observation logs (last 100 entries)
```json
{
  "observations": [
    {
      "timestamp": "2026-09-04T12:00:00Z",
      "event_type": "ssrf_redirect_attempt",
      "client_ip": "192.0.2.1",
      "user_agent": "Scanner/1.0",
      "details": {"target": "fargate", "redirect_to": "http://169.254.170.2"}
    }
  ],
  "total_files": 1
}
```
- **Purpose**: Access observation logs for verification

#### GET /health
- **Response**: 200 OK
- **Content-Type**: `application/json`
- **Body**: `{"status": "healthy", "service": "paleon-site7"}`
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
- `Transfer-Encoding`: chunked (slow-body, large-body)
- `Content-Encoding`: gzip (gzip-bomb)

### Malformed Endpoints
- `Transfer-Encoding`: chunked (malformed/chunked)
- No special headers (malformed/banner)

---

## Error Responses

| Status | Condition |
|--------|-----------|
| 404 | Unknown endpoint |
| 405 | Method not allowed (e.g., POST /hostile/read-only) |
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
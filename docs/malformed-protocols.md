# PALEON TEST SITE 7 — Malformed Protocol Test Design

## Overview

This document describes the malformed protocol test endpoints in Site 7. These tests validate that the scanner parses HTTP/TLS responses defensively without crashing, executing response content, or hanging.

---

## 1. Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Isolated from main app** | Separate server processes on localhost:9998 (malformed TLS) and localhost:9999 (malformed HTTP) |
| **No main site breakage** | Nginx/Flask app remains standards-compliant |
| **Contained scope** | Only accessible via SNI routing on port 443 |
| **Deterministic** | Same malformed responses every time |
| **No code execution** | Pure protocol violations, no payloads |
| **Observable** | Structured logging of every connection |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      SCANNER (External)                         │
└─────────────────────────────────────────────────────────────────┘
                                    │
                          ┌─────────┴─────────┐
                          ▼                   ▼
              ┌───────────────────┐   ┌───────────────────┐
              │   Nginx :80/:443  │   │  DNS :53          │
              │  SNI Routing      │   │  (Rebinding)      │
              └─────────┬─────────┘   └───────────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
┌──────────────────┐ ┌─────────┐ ┌─────────┐
│  Default Backend │ │:9998    │ │:9999    │
│  127.0.0.1:8443  │ │Malformed│ │Malformed│
│  → Flask :5000   │ │ TLS     │ │ HTTP    │
└──────────────────┘ └─────────┘ └─────────┘
```

**Key Separation**: The main Flask app serves standards-compliant endpoints. The **actual malformed protocol violations** are served by separate servers:
- **Port 9998**: Raw malformed TLS (garbled ServerHello)
- **Port 9999**: Valid TLS handshake → raw malformed HTTP bytes

Nginx SNI routing on port 443 directs traffic:
- `malformed-tls.paleon-lab-hostile.com` → 127.0.0.1:9998
- `malformed-http.paleon-lab-hostile.com` → 127.0.0.1:9999
- `default` → 127.0.0.1:8443 → Flask app on 127.0.0.1:5000

This ensures:
- Main site passes TLS/HTTP compliance checks
- Malformed tests don't affect legitimate traffic
- Scanner can be pointed specifically at malformed subdomains for testing

---

## 3. Test Cases

### 3.1 Invalid Chunked Encoding (`/malformed/chunked`)

**Endpoint**: `https://malformed-http.paleon-lab-hostile.com/malformed/chunked`

**Violation**: Invalid chunked encoding with garbage chunk length

**Raw Response** (after valid TLS handshake):
```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked

5
HELLO
GARBAGE
0

```

**Specific Violations**:
1. `GARBAGE` — Not a valid hex chunk length (should be hex digits only)
2. Proper terminator `0\r\n\r\n` at end (to test parser recovery)

**Expected Scanner Behavior**:
- ✅ Detect invalid hex length, reject response
- ✅ Not crash, not hang, not execute content
- ✅ Log parsing error and continue scan

---

### 3.2 Junk HTTP Banner (`/malformed/banner`)

**Endpoint**: `https://malformed-http.paleon-lab-hostile.com/malformed/banner`

**Violation**: HTTP response with control characters in header value

**Raw Response** (after valid TLS handshake):
```
HTTP/1.1 200 OK
X-Control-Header: \x00\x01\x02\x03
Content-Length: 14

MALFORMED_HEADER
```

**Specific Violations**:
1. Control characters in header value (`\x00-\x03`)
2. Binary data in response body
3. Non-UTF-8 sequences

**Expected Scanner Behavior**:
- ✅ Handle binary headers without crash
- ✅ Handle binary body without crash
- ✅ Not interpret binary data as commands
- ✅ Close connection cleanly

---

### 3.3 Malformed TLS (`https://malformed-tls.paleon-lab-hostile.com/`)

**Endpoint**: `https://malformed-tls.paleon-lab-hostile.com/`

**Violation**: Garbled TLS ServerHello during handshake

**Raw Response** (TLS Record Layer):
```
0x16 0x03 0x03 0x00 0x10 0x02 0x00 0x00 0x0c 0x03 0x03
0xFF 0xFE 0xFD 0xFC 0xFB 0xFA 0xF9 0xF8 0xF7 0xF6
```

**Breakdown**:
- `0x16` — TLS Record Type: Handshake (22)
- `0x03 0x03` — TLS Version: 1.2
- `0x00 0x10` — Record Length: 16 bytes
- `0x02` — Handshake Type: ServerHello (2)
- `0x00 0x00 0x0c` — Handshake Length: 12 bytes
- `0x03 0x03` — Version: TLS 1.2
- `0xFF 0xFE 0xFD 0xFC 0xFB 0xFA 0xF9 0xF8 0xF7 0xF6` — **GARBAGE** (10 bytes of invalid random/version data)

**Expected Scanner Behavior**:
- ✅ Detect malformed ServerHello during handshake
- ✅ TLS library raises SSL error / handshake failure
- ✅ Not crash, not hang
- ✅ Fail certificate validation cleanly
- ✅ Log TLS error and continue scan

---

## 4. Server Implementation Details

### Malformed TLS Server (Port 9998)

```python
HOST = '127.0.0.1'
PORT_TLS = 9998
MAX_CONNECTIONS = 10
IDLE_TIMEOUT = 30
```

**Behavior**:
1. Accepts TCP connection
2. Reads ClientHello (fragmentation-tolerant)
3. Sends garbled ServerHello (see 3.3 above)
4. Closes connection

**Connection Management**:
- Connection cap: 10 concurrent
- Idle reaper: Background thread checks every 5s, closes connections idle >30s
- Bounded worker pool: each accepted connection runs on a `ThreadPoolExecutor` worker guarded by a `BoundedSemaphore`, so no more than the cap run concurrently

---

### Malformed HTTP Server (Port 9999)

```python
HOST = '127.0.0.1'
PORT_HTTP = 9999
MAX_CONNECTIONS = 10
IDLE_TIMEOUT = 30
CERT_FILE = "/etc/ssl/site7/site7.crt"
KEY_FILE = "/etc/ssl/site7/site7.key"
```

**Behavior**:
1. Accepts TCP connection
2. Performs valid TLS handshake using site certificate
3. Reads HTTP request headers (fragmentation-tolerant)
4. Routes based on request path:
   - `/malformed/chunked` → Invalid chunked encoding
   - `/malformed/banner` → Control chars in header
5. Sends malformed HTTP response
6. Attempts graceful TLS unwrap
7. Closes connection

**Connection Management**:
- Connection cap: 10 concurrent
- Idle reaper: Background thread checks every 5s, closes connections idle >30s
- Bounded worker pool: each accepted connection runs on a `ThreadPoolExecutor` worker guarded by a `BoundedSemaphore`, so no more than the cap run concurrently

---

### Logging (Both Servers)

Structured JSON for every event:
- `connection_accepted` — New connection with ID, client IP
- `request_received` — Truncated request preview (no sensitive data)
- `response_sent` — Response type, size
- `connection_error` — Any exception
- `connection_closed` — Normal close
- `idle_connection_closed` — Reaper action
- `connection_rejected_capacity` — At max connections

---

## 5. Expected Scanner Behavior (SAFE-004 / SAFE-004-TLS)

| Test | Scanner Must |
|------|--------------|
| Invalid Chunked (SAFE-004) | Detect malformed chunk lengths; not crash; not hang; fail gracefully |
| Junk Banner (SAFE-004) | Handle binary headers/body; not crash; close connection cleanly |
| Malformed TLS (SAFE-004-TLS) | Detect invalid TLS handshake; not crash; fail certificate validation |

### Fail Criteria
- ❌ Scanner segfaults, panics, or exits abnormally
- ❌ Scanner hangs indefinitely on malformed response
- ❌ Scanner executes/ interprets binary response content
- ❌ Scanner accepts invalid chunked encoding as valid
- ❌ Scanner continues scan but in corrupted state

---

## 6. Verification Commands

### Invalid Chunked (via SNI)
```bash
# From external - connects to malformed-http subdomain on 443
curl -I https://malformed-http.paleon-lab-hostile.com/malformed/chunked

# Raw connection via SNI (requires OpenSSL s_client)
openssl s_client -connect malformed-http.paleon-lab-hostile.com:443 -servername malformed-http.paleon-lab-hostile.com << 'EOF'
GET /malformed/chunked HTTP/1.1
Host: malformed-http.paleon-lab-hostile.com

EOF
```

### Junk Banner (via SNI)
```bash
curl -I https://malformed-http.paleon-lab-hostile.com/malformed/banner

openssl s_client -connect malformed-http.paleon-lab-hostile.com:443 -servername malformed-http.paleon-lab-hostile.com << 'EOF'
GET /malformed/banner HTTP/1.1
Host: malformed-http.paleon-lab-hostile.com

EOF
```

### Malformed TLS (via SNI)
```bash
# Should fail with SSL error
curl -I https://malformed-tls.paleon-lab-hostile.com/

# Raw TLS handshake
openssl s_client -connect malformed-tls.paleon-lab-hostile.com:443 -servername malformed-tls.paleon-lab-hostile.com
```

---

## 7. Safety Guarantees

### What These Tests CANNOT Do

| Myth | Reality |
|------|---------|
| "Executes shell commands" | Pure HTTP/TLS response; no shell, no eval |
| "Installs malware" | Static bytes; no file write, no execution |
| "Exfiltrates data" | Server only sends; doesn't read request body |
| "Crashes the OS" | User-space TCP server; kernel unaffected |
| "Persists" | No disk writes; in-memory only |

### Server Self-Protection
- Connection limit prevents resource exhaustion
- Idle timeout prevents connection leaks
- Daemon threads die with main process
- No global state that survives restart
- Bounded read buffers (4096 bytes max)

---

## 8. Integration with expected.yaml

```yaml
- id: SAFE-004
  category: parser_safety
  targets:
    - https://malformed-http.paleon-lab-hostile.com/malformed/chunked
    - https://malformed-http.paleon-lab-hostile.com/malformed/banner
  expect: "malformed response parsed defensively; scanner does not crash"
  severity: high
  claim: observed

- id: SAFE-004-TLS
  category: parser_safety
  target: https://malformed-tls.paleon-lab-hostile.com/
  expect: "malformed TLS ServerHello parsed defensively; scanner does not crash"
  severity: high
  claim: observed
```

---

## 9. Troubleshooting

| Issue | Cause | Resolution |
|-------|-------|------------|
| Server won't start | Port 9998/9999 in use | `ss -tlnp | grep -E '9998|9999'` and kill |
| Connections rejected | At MAX_CONNECTIONS | Wait for idle reaper or increase limit |
| No logs | Logging not configured | Check stdout/stderr; JSONFormatter outputs to stdout |
| Scanner doesn't see malformed | Testing wrong endpoint | Use `https://malformed-http...` or `https://malformed-tls...` on 443 |
| TLS cert missing | Certbot failed, self-signed used | Check `/etc/ssl/site7/site7.crt` and `.key` exist |
| Permission denied on key | Key permissions wrong | `chmod 640 /etc/ssl/site7/site7.key && chown root:site7-tls /etc/ssl/site7/site7.key` |

---

## 10. Future Enhancements

1. **HTTP/2 Malformed**: Add h2c cleartext HTTP/2 with invalid frames
2. **HTTP Smuggling**: TE.CL and CL.TE desync test cases
3. **Response Splitting**: Header injection test cases
4. **WebSocket Malformed**: Invalid WebSocket handshake frames
5. **Additional TLS violations**: Invalid certificates, heartbeat misuse, version rollback
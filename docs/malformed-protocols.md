# PALEON TEST SITE 7 — Malformed Protocol Test Design

## Overview

This document describes the malformed protocol test endpoints in Site 7. These tests validate that the scanner parses HTTP/TLS responses defensively without crashing, executing response content, or hanging.

---

## 1. Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Isolated from main app** | Separate server process on localhost:9999 |
| **No main site breakage** | Nginx/Flask app remains standards-compliant |
| **Contained scope** | Only accessible via localhost or explicit test config |
| **Deterministic** | Same malformed responses every time |
| **No code execution** | Pure protocol violations, no payloads |
| **Observable** | Structured logging of every connection |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      SCANNER (External)                          │
└─────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
        ┌───────────────────────┐         ┌───────────────────────┐
        │   Nginx :80/:443      │         │  Malformed Server     │
        │   (Standards Compliant)│         │  :9999 (localhost)    │
        └───────────┬───────────┘         └───────────┬───────────┘
                    │                               │
                    ▼                               ▼
        ┌───────────────────────┐         ┌───────────────────────┐
        │   Flask App :5000     │         │  - Invalid Chunked    │
        │   /malformed/*        │         │  - Junk Banner        │
        │   (Placeholders)      │         │  (No TLS test here)   │
        └───────────────────────┘         └───────────────────────┘
```

**Key Separation**: The main Flask app provides *placeholder* endpoints for malformed tests (returning 200 with explanation). The **actual malformed protocol violations** are served by the separate `malformed_server.py` on localhost:9999. This ensures:
- Main site passes TLS/HTTP compliance checks
- Malformed tests don't affect legitimate traffic
- Scanner can be pointed specifically at malformed endpoints for testing

---

## 3. Test Cases

### 3.1 Invalid Chunked Encoding (`/malformed/chunked`)

**Endpoint**: `http://127.0.0.1:9999/malformed/chunked`

**Violation**: Multiple chunked encoding errors in single response

**Raw Response**:
```
HTTP/1.1 200 OK
Transfer-Encoding: chunked
Content-Type: text/plain
X-Test: malformed-chunked

5
hello
GARBAGE
3
foo

0

```

**Specific Violations**:
1. `GARBAGE` — Not a valid hex chunk length
2. Empty line after `3\r\nfoo\r\n` — Missing chunk data for what should be a 3-byte chunk
3. Proper terminator `0\r\n\r\n` at end (to test parser recovery)

**Expected Scanner Behavior**:
- ✅ Detect invalid hex length, reject response
- ✅ Detect missing chunk data, reject response
- ✅ Not crash, not hang, not execute content
- ✅ Log parsing error and continue scan

---

### 3.2 Junk HTTP Banner (`/malformed/banner`)

**Endpoint**: `http://127.0.0.1:9999/malformed/banner`

**Violation**: HTTP-like response with binary garbage in headers and body

**Raw Response**:
```
HTTP/1.1 200 OK
Server: Paleon-Hostile-Malformed/7.0
X-Junk-Banner: \x00\x01\x02\x03\xFF\xFE\xFD\xFC
Content-Type: text/plain
Connection: close

This is a junk HTTP banner response.\x00\x01\x02\x03
\xFF\xFE\xFD\xFC\xFB\xFA\xF9
Extra garbage: \x80\x81\x82\x83\x84\x85
```

**Specific Violations**:
1. Control characters in header value (`\x00-\x03`, `\xFC-\xFF`)
2. Binary data in response body
3. Non-UTF-8 sequences
4. No `Content-Length`, uses `Connection: close`

**Expected Scanner Behavior**:
- ✅ Handle binary headers without crash
- ✅ Handle binary body without crash
- ✅ Not interpret binary data as commands
- ✅ Close connection cleanly

---

### 3.3 Malformed TLS (Placeholder in Main App, Separate Listener Required)

**Main App Endpoint**: `GET /hostile/malformed/tls` → Returns explanatory text

**Actual Test**: Requires a separate TLS listener that:
- Sends invalid ClientHello
- Sends garbled ServerHello
- Uses wrong TLS version
- Sends certificate with invalid ASN.1
- Performs heartbeat extension misuse (like Heartbleed test)

**Implementation Note**: 
> A full malformed TLS test requires a custom TLS stack (not OpenSSL) because OpenSSL validates before handing to application. Options:
> 1. Use `scapy` to craft raw TLS records
> 2. Use a modified `tlslite-ng` or similar
> 3. Use a dedicated fuzzer like `tlsfuzzer`
> 4. Document as "requires separate TLS test harness"

**For Site 7**: The placeholder endpoint documents this requirement. A production test harness would deploy a separate TLS fuzzer on another localhost port.

---

## 4. Malformed Server Implementation (`app/malformed_server.py`)

### Server Configuration
```python
HOST = '127.0.0.1'
PORT = 9999
MAX_CONNECTIONS = 10
IDLE_TIMEOUT = 30  # seconds
```

### Connection Management
- **Connection cap**: 10 concurrent connections
- **Idle reaper**: Background thread checks every 5s, closes connections idle >30s
- **Thread-per-connection**: Each request handled in daemon thread
- **Graceful shutdown**: `KeyboardInterrupt` closes all connections

### Request Handling
```python
# Reads request headers only (up to \r\n\r\n)
# Determines response type by path:
#   /malformed/chunked  -> invalid chunked
#   /malformed/banner   -> junk banner
#   (default)           -> invalid chunked
```

### Logging
Structured JSON for every event:
- `connection_accepted` — New connection with ID, client IP
- `request_received` — Truncated request preview (no sensitive data)
- `response_sent` — Response type, size
- `connection_error` — Any exception
- `connection_closed` — Normal close
- `idle_connection_closed` — Reaper action
- `connection_rejected_capacity` — At max connections

---

## 5. Expected Scanner Behavior (SAFE-004)

| Test | Scanner Must |
|------|--------------|
| Invalid Chunked | Detect malformed chunk lengths; not crash; not hang; fail gracefully |
| Junk Banner | Handle binary headers/body; not crash; close connection cleanly |
| Malformed TLS* | Detect invalid TLS handshake; not crash; fail certificate validation |

*Malformed TLS requires separate test harness

### Fail Criteria
- ❌ Scanner segfaults, panics, or exits abnormally
- ❌ Scanner hangs indefinitely on malformed response
- ❌ Scanner executes/ interprets binary response content
- ❌ Scanner accepts invalid chunked encoding as valid
- ❌ Scanner continues scan but in corrupted state

---

## 6. Verification Commands

### Invalid Chunked
```bash
# Raw connection to see malformed response
nc 127.0.0.1 9999 << 'EOF'
GET /malformed/chunked HTTP/1.1
Host: localhost

EOF
```

### Junk Banner
```bash
nc 127.0.0.1 9999 << 'EOF'
GET /malformed/banner HTTP/1.1
Host: localhost

EOF
```

### Using curl (will likely fail/close)
```bash
# These will show curl's handling of malformed responses
curl -v http://127.0.0.1:9999/malformed/chunked
curl -v http://127.0.0.1:9999/malformed/banner
```

---

## 7. Safety Guarantees

### What These Tests CANNOT Do

| Myth | Reality |
|------|---------|
| "Executes shell commands" | Pure HTTP response; no shell, no eval |
| "Installs malware" | Static bytes; no file write, no execution |
| "Exfiltrates data" | Server only sends; doesn't read request body |
| "Crashes the OS" | User-space TCP server; kernel unaffected |
| "Persists" | No disk writes; in-memory only |

### Server Self-Protection
- Connection limit prevents resource exhaustion
- Idle timeout prevents connection leaks
- Daemon threads die with main process
- No global state that survives restart

---

## 8. Integration with expected.yaml

```yaml
- id: SAFE-004
  category: parser_safety
  targets:
    - https://paleon-lab-hostile.com/hostile/malformed/chunked
    - https://paleon-lab-hostile.com/hostile/malformed/banner
  expect: "malformed response parsed defensively; scanner does not crash"
  severity: high
  claim: observed
```

**Note**: The `expected.yaml` references the main app placeholder endpoints. The actual malformed tests require pointing the scanner at `http://127.0.0.1:9999/malformed/*` directly (or configuring the scanner to test the malformed server port).

---

## 9. Troubleshooting

| Issue | Cause | Resolution |
|-------|-------|------------|
| Server won't start | Port 9999 in use | `ss -tlnp | grep 9999` and kill |
| Connections rejected | At MAX_CONNECTIONS | Wait for idle reaper or increase limit |
| No logs | Logging not configured | Check stdout/stderr; JSONFormatter outputs to stdout |
| Scanner doesn't see malformed | Testing wrong endpoint | Use `http://127.0.0.1:9999/...` not `https://.../hostile/malformed/...` |

---

## 10. Future Enhancements

1. **Malformed TLS Harness**: Deploy `tlsfuzzer` or custom TLS stack on port 9998
2. **HTTP/2 Malformed**: Add h2c cleartext HTTP/2 with invalid frames
3. **HTTP Smuggling**: TE.CL and CL.TE desync test cases
4. **Response Splitting**: Header injection test cases
5. **WebSocket Malformed**: Invalid WebSocket handshake frames
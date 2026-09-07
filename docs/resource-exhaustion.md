# PALEON TEST SITE 7 — Resource Exhaustion Test Design

## Overview

This document describes the resource exhaustion test endpoints in Site 7. These tests validate that the scanner enforces limits on response body size, read duration, and decompression size without crashing, hanging, or consuming unbounded resources.

---

## 1. Design Principles

| Principle | Implementation |
|-----------|----------------|
| **No giant files in Git** | All payloads generated programmatically at runtime |
| **No RAM allocation** | Streaming generators yield chunks; never `bytes(payload)` |
| **Configurable limits** | Query parameters with hard ceilings |
| **Server-side protection** | Application enforces maximums regardless of input |
| **Deterministic** | Same parameters always produce same behavior |
| **Cleanup guaranteed** | Generators close properly; no background threads |

---

## 2. Large Body Test (`/hostile/large-body`)

### Purpose
Test scanner's response body size limit enforcement.

### Endpoint
```
GET /hostile/large-body?size_mb=N
```

### Parameters
| Parameter | Default | Min | Max | Description |
|-----------|---------|-----|-----|-------------|
| `size_mb` | 10 | 1 | 20 | Response size in megabytes |

### Implementation

```python
def generate_large_body(size_bytes: int, chunk_size: int = 65536) -> Generator[bytes, None, None]:
    """Generate bytes in chunks without allocating full payload in RAM."""
    remaining = size_bytes
    while remaining > 0:
        chunk = min(chunk_size, remaining)
        yield os.urandom(chunk)  # Cryptographically random bytes
        remaining -= chunk
```

**Key properties**:
- Streams `os.urandom()` in 64KB chunks
- Never holds more than 64KB in memory at once
- `Content-Length` header set to exact size
- `Content-Type: application/octet-stream`

### Server-Side Ceilings

```python
MAX_BODY_SIZE = 20 * 1024 * 1024  # 20 MB absolute maximum
size_mb = max(1, min(size_mb, MAX_BODY_SIZE // (1024 * 1024)))  # Clamped in endpoint
```

Even if attacker sends `size_mb=1000`, server clamps to 20MB.

### Expected Scanner Behavior

| Scanner Action | Pass/Fail |
|----------------|-----------|
| Reads up to configured limit, then stops | ✅ PASS |
| Truncates response at limit | ✅ PASS |
| Streams without loading full body | ✅ PASS |
| OOM crash | ❌ FAIL |
| Hangs reading unbounded stream | ❌ FAIL |
| Stores full 20MB in RAM | ❌ FAIL (inefficient) |

### Evidence to Collect
- Scanner's configured body size limit
- Actual bytes read before termination
- Memory usage during test
- Scan completion status

---

## 3. Slow Body Test (`/hostile/slow-body`)

### Purpose
Test scanner's read timeout and total time budget enforcement.

### Endpoint
```
GET /hostile/slow-body?delay_ms=N
```

### Parameters
| Parameter | Default | Min | Max | Description |
|-----------|---------|-----|-----|-------------|
| `delay_ms` | 5000 | 100 | 15000 | Total delay in milliseconds |

### Implementation

```python
def generate_slow_body(delay_ms: int, chunks: int = 10) -> Generator[bytes, None, None]:
    """Generate small chunks with delay between each."""
    chunk_data = b"x" * 1024  # 1KB per chunk
    delay_per_chunk = delay_ms / chunks / 1000.0  # Convert to seconds

    for _ in range(chunks):
        yield chunk_data
        time.sleep(delay_per_chunk)
```

**Key properties**:
- 10 chunks of 1KB each (10KB total)
- Even delay distribution across chunks
- `time.sleep()` in generator (blocks that worker only)
- No `Content-Length` (uses chunked transfer encoding)

### Server-Side Ceilings

```python
MAX_DELAY = 15000  # 15 seconds absolute maximum
delay_ms = max(100, min(delay_ms, MAX_DELAY))  # Clamped in endpoint
```

### Expected Scanner Behavior

| Scanner Action | Pass/Fail |
|----------------|-----------|
| Enforces per-read timeout | ✅ PASS |
| Enforces total request timeout | ✅ PASS |
| Cancels connection after timeout | ✅ PASS |
| Hangs indefinitely | ❌ FAIL |
| Accumulates data without timeout | ❌ FAIL |
| Crashes on slow stream | ❌ FAIL |

### Evidence to Collect
- Scanner's configured read timeout
- Actual time before termination
- Connection state after timeout
- Scan completion status

---

## 4. Gzip Bomb Test (`/hostile/gzip-bomb`)

### Purpose
Test scanner's decompression size limit enforcement.

### Endpoint
```
GET /hostile/gzip-bomb
```

### Implementation

```python
def generate_gzip_bomb_stream(
    decompressed_size: int = MAX_GZIP_DECOMPRESSED,   # 10 MB
    input_chunk: int = 64 * 1024,
) -> Generator[bytes, None, None]:
    """Stream a valid gzip member that decompresses to decompressed_size."""
    size = min(decompressed_size, MAX_GZIP_DECOMPRESSED)
    compressor = zlib.compressobj(level=9, wbits=31)  # wbits=31 => gzip framing
    remaining = size
    zeros = b"\x00" * input_chunk
    while remaining > 0:
        n = min(input_chunk, remaining)
        block = zeros if n == input_chunk else b"\x00" * n
        out = compressor.compress(block)
        remaining -= n
        if out:
            yield out
    tail = compressor.flush()
    if tail:
        yield tail
```

**Key properties**:
- ~10KB compressed → ~10MB decompressed (~1000:1 ratio)
- Streamed per request with `zlib.compressobj(level=9, wbits=31)`; the 10 MB of zeros is never buffered in RAM
- `Content-Encoding: gzip` header
- No `Content-Length` (response is streamed)
- `X-Decompressed-Size: 10485760` header (for verification)

### Server-Side Ceilings

```python
decompressed_size = MAX_GZIP_DECOMPRESSED  # 10 MB — the only ceiling
# generate_gzip_bomb_stream() clamps its argument to MAX_GZIP_DECOMPRESSED
# and streams the gzip member, so the decompressed payload can never exceed 10 MB.
```

### Expected Scanner Behavior

| Scanner Action | Pass/Fail |
|----------------|-----------|
| Decompresses up to limit, then stops | ✅ PASS |
| Rejects response exceeding decompression ceiling | ✅ PASS |
| Streams decompression without full RAM allocation | ✅ PASS |
| OOM during decompression | ❌ FAIL |
| Decompresses full 10MB+ without limit | ❌ FAIL |
| Crashes on malformed gzip | ❌ FAIL |

### Evidence to Collect
- Scanner's decompression size limit
- Actual decompressed bytes processed
- Memory usage during decompression
- Scan completion status

---

## 5. Combined Resource Protection

### Server-Side Resource Limits

| Resource | Limit | Enforcement |
|----------|-------|-------------|
| Response body size | 20 MB | Clamped in endpoint |
| Response duration | 15 s | Clamped in endpoint |
| Compressed gzip output | ~10 KB | Streamed (no Content-Length) |
| Decompressed size | 10 MB (test) | Documented in header |
| Concurrent connections | Bounded by Nginx + threaded Flask | Nginx stream/http limits |
| Peak response memory | ~64 KB (largest stream chunk) | Generators never buffer full body |

### Client-Side (Scanner) Expected Limits

| Limit | Recommended Value |
|-------|-------------------|
| Max response body | 10 MB |
| Max read timeout | 30 s |
| Max total request time | 60 s |
| Max decompression size | 50 MB |
| Max redirect hops | 10 |
| Max concurrent connections | 10 |

---

## 6. Safety Guarantees

### What These Tests CANNOT Do

| Myth | Reality |
|------|---------|
| "Fills disk" | No file I/O; pure streaming |
| "Allocates GB of RAM" | Max 64KB chunk in generator |
| "Creates infinite loop" | Bounded by parameters + hard ceilings |
| "Exhausts CPU" | `os.urandom()` and `time.sleep()` are low CPU |
| "Leaves background threads" | All generators; no daemon threads |

### Verification Commands

```bash
# Test large body (1MB - quick)
curl -k --max-time 10 -o /dev/null -w "Size: %{size_download}\n" \
  "https://paleon-lab-hostile.com/hostile/large-body?size_mb=1"

# Test slow body (100ms - quick)
curl -k --max-time 5 -o /dev/null -w "Time: %{time_total}\n" \
  "https://paleon-lab-hostile.com/hostile/slow-body?delay_ms=100"

# Test gzip bomb
curl -k -H "Accept-Encoding: gzip" --max-time 10 \
  "https://paleon-lab-hostile.com/hostile/gzip-bomb" \
  -o /tmp/bomb.gz -w "Compressed: %{size_download}\n"
gzip -dc /tmp/bomb.gz | wc -c  # Should be ~10MB
```

---

## 7. Integration with expected.yaml

```yaml
- id: SAFE-003
  category: resource_safety
  targets:
    - https://paleon-lab-hostile.com/hostile/large-body
    - https://paleon-lab-hostile.com/hostile/slow-body
    - https://paleon-lab-hostile.com/hostile/gzip-bomb
  expect: "response size and duration bounded by scanner limits; no resource runaway"
  severity: high
  claim: observed
```

---

## 8. Parameter Reference

### Large Body
| size_mb | Compressed? | Chunk Size | Content-Length |
|---------|-------------|------------|----------------|
| 1 | No | 64KB | 1,048,576 |
| 10 (default) | No | 64KB | 10,485,760 |
| 20 (max) | No | 64KB | 20,971,520 |

### Slow Body
| delay_ms | Chunks | Chunk Size | Total Data | Delay/Chunk |
|----------|--------|------------|------------|-------------|
| 100 (min) | 10 | 1KB | 10KB | 10ms |
| 5000 (default) | 10 | 1KB | 10KB | 500ms |
| 15000 (max) | 10 | 1KB | 10KB | 1500ms |

### Gzip Bomb
| Metric | Value |
|--------|-------|
| Compressed size | ~10 KB (streamed; not sent as a `Content-Length`) |
| Decompressed size | 10,485,760 bytes (10 MB) |
| Compression ratio | ~1000:1 |
| Generation | Regenerated on every request (streamed on the fly; not cached) |

---

## 9. Troubleshooting

| Issue | Cause | Resolution |
|-------|-------|------------|
| Response truncated | Nginx `client_max_body_size` | Set `client_max_body_size 100M;` in nginx.conf |
| Timeout on large body | Scanner limit too low | Increase scanner body limit |
| Gzip bomb not decompressing | Scanner doesn't auto-decompress | Test requires scanner with gzip support |
| Memory spike | Not streaming | Verify `stream_with_context` used in Flask |
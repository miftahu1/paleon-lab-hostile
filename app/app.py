#!/usr/bin/env python3
"""
PALEON SITE 7 — HOSTILE TEST TARGET — DO NOT USE FOR PRODUCTION

Flask application for hostile scanner resilience testing.
Provides endpoints to test SSRF, DNS rebinding, redirect loops, resource exhaustion,
malformed responses, and scope escape attempts.

Security constraints:
- No outbound network calls
- No database, no authentication, no sessions
- Resource limits enforced (MAX_BODY_SIZE=50MB, MAX_DELAY=30000ms)
- Structured JSON logging without credentials/secrets
- Streaming responses to avoid RAM allocation
"""

import os
import sys
import json
import time
import logging
import threading
import gzip
import io
from functools import wraps
from datetime import datetime, timezone
from typing import Generator, Optional

from flask import Flask, request, Response, redirect, jsonify, stream_with_context

# ============================================================================
# Configuration Constants
# ============================================================================
MAX_BODY_SIZE = 20 * 1024 * 1024  # 20 MB (default 10MB, max 20MB)
MAX_DELAY = 30000  # 30 seconds
MAIN_PORT = 5000
MALFORMED_PORT = 9999
DNS_PORT = 53

# ============================================================================
# Structured Logging Setup
# ============================================================================
class JSONFormatter(logging.Formatter):
    """JSON log formatter that excludes sensitive data."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        # Add extra fields from record
        for key, value in record.__dict__.items():
            if key not in ('name', 'msg', 'args', 'created', 'filename', 'funcName',
                           'levelname', 'levelno', 'lineno', 'module', 'msecs',
                           'message', 'msg', 'name', 'pathname', 'process',
                           'processName', 'relativeCreated', 'thread', 'threadName',
                           'exc_info', 'exc_text', 'stack_info'):
                # Filter out sensitive fields
                if key.lower() not in ('cookie', 'authorization', 'password', 'secret',
                                       'token', 'api_key', 'apikey', 'credential'):
                    log_entry[key] = value

        return json.dumps(log_entry)


# Configure logger
logger = logging.getLogger("paleon.site7")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)

# ============================================================================
# Observations Storage (in-memory, thread-safe)
# ============================================================================
class ObservationStore:
    """Thread-safe in-memory storage for endpoint observations."""

    def __init__(self):
        self._lock = threading.Lock()
        self._observations = []

    def add(self, observation: dict):
        with self._lock:
            self._observations.append(observation)

    def get_all(self) -> list:
        with self._lock:
            return list(self._observations)

    def clear(self):
        with self._lock:
            self._observations.clear()


observation_store = ObservationStore()

# ============================================================================
# Logging Helper
# ============================================================================
def log_test_hit(test_id: str, method: str, path: str, status: int,
                 redirect_dest: Optional[str] = None, body_size: int = 0,
                 delay_profile: Optional[str] = None, off_scope: bool = False,
                 **extra):
    """Log a test endpoint hit with structured data."""
    logger.info(
        "test_endpoint_hit",
        extra={
            "test_id": test_id,
            "method": method,
            "path": path,
            "status": status,
            "redirect_destination": redirect_dest,
            "body_size_bytes": body_size,
            "delay_profile": delay_profile,
            "off_scope_attempt": off_scope,
            **extra
        }
    )


def log_observation(test_id: str, method: str, path: str, headers: dict, **extra):
    """Log an observation for read-only endpoint."""
    obs = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "test_id": test_id,
        "method": method,
        "path": path,
        "headers": {k: v for k, v in headers.items()
                    if k.lower() not in ('cookie', 'authorization', 'password', 'secret', 'token')},
        **extra
    }
    observation_store.add(obs)


# ============================================================================
# Decorators
# ============================================================================
def localhost_only(f):
    """Restrict endpoint to localhost only."""
    @wraps(f)
    def wrapper(*args, **kwargs):
        if request.remote_addr not in ('127.0.0.1', '::1', 'localhost'):
            return jsonify({"error": "Access denied: localhost only"}), 403
        return f(*args, **kwargs)
    return wrapper


# ============================================================================
# Streaming Generators
# ============================================================================
def generate_large_body(size_bytes: int, chunk_size: int = 65536) -> Generator[bytes, None, None]:
    """Generate bytes in chunks without allocating full payload in RAM."""
    remaining = size_bytes
    while remaining > 0:
        chunk = min(chunk_size, remaining)
        yield os.urandom(chunk)
        remaining -= chunk


def generate_slow_body(delay_ms: int, chunks: int = 10) -> Generator[bytes, None, None]:
    """Generate small chunks with delay between each."""
    chunk_data = b"x" * 1024  # 1KB per chunk
    delay_per_chunk = delay_ms / chunks / 1000.0  # Convert to seconds

    for _ in range(chunks):
        yield chunk_data
        time.sleep(delay_per_chunk)


def generate_gzip_bomb_stream(decompressed_size: int = 10 * 1024 * 1024, chunk_size: int = 1024 * 1024) -> Generator[bytes, None, None]:
    """Stream a gzip-compressed payload that decompresses to ~10MB without allocating full payload in RAM."""
    # Create a gzip stream that writes repetitive data (zeros) in chunks
    # This avoids allocating the full decompressed payload in memory
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', compresslevel=9) as gz:
        # Write zero bytes in chunks to the gzip stream
        for i in range(0, decompressed_size, chunk_size):
            write_size = min(chunk_size, decompressed_size - i)
            gz.write(b"\x00" * write_size)
            # Yield whatever has been compressed so far
            pos = buf.tell()
            if pos > 0:
                buf.seek(0)
                yield buf.read(pos)
                buf.seek(0)
                buf.truncate(0)

    # Flush any remaining compressed data
    pos = buf.tell()
    if pos > 0:
        buf.seek(0)
        yield buf.read(pos)


# ============================================================================
# Flask Application
# ============================================================================
app = Flask(__name__)

# ============================================================================
# Landing Page
# ============================================================================
@app.route('/')
def landing():
    """Landing page with test category listing."""
    html = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Paleon Site 7 — Hostile Scanner Resilience Lab</title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            line-height: 1.6;
            max-width: 800px;
            margin: 0 auto;
            padding: 2rem 1rem;
            color: #1a1a1a;
            background: #fafafa;
        }
        header { margin-bottom: 2rem; }
        h1 { font-size: 1.8rem; font-weight: 600; margin-bottom: 0.5rem; }
        .subtitle { color: #666; font-size: 1.1rem; }
        nav { margin: 1.5rem 0; }
        nav ul { list-style: none; padding: 0; display: grid; gap: 0.75rem; }
        nav li { background: white; border: 1px solid #e0e0e0; border-radius: 6px; padding: 1rem; transition: border-color 0.2s; }
        nav li:hover { border-color: #999; }
        nav a { text-decoration: none; color: #1a1a1a; font-weight: 500; display: block; }
        nav a:focus { outline: 2px solid #0066cc; outline-offset: 2px; border-radius: 4px; }
        .category { font-size: 0.9rem; color: #666; margin-top: 0.25rem; }
        .endpoints { display: grid; gap: 0.5rem; margin-top: 0.5rem; font-size: 0.85rem; font-family: monospace; color: #444; }
        .endpoint { background: #f5f5f5; padding: 0.4rem 0.6rem; border-radius: 4px; }
        .warning { background: #fff3cd; border: 1px solid #ffc107; padding: 1rem; border-radius: 6px; margin-bottom: 1.5rem; }
        .warning strong { color: #856404; }
        footer { margin-top: 3rem; padding-top: 1.5rem; border-top: 1px solid #e0e0e0; color: #888; font-size: 0.85rem; }
        @media (max-width: 600px) {
            body { padding: 1rem; }
            h1 { font-size: 1.5rem; }
        }
    </style>
</head>
<body>
    <header>
        <h1>Paleon Site 7 — Hostile Scanner Resilience Lab</h1>
        <p class="subtitle">Test endpoints for scanner resilience evaluation. <strong>Not for production use.</strong></p>
    </header>

    <div class="warning">
        <strong>Warning:</strong> These endpoints are designed to stress-test scanners and may cause hangs, crashes, or unexpected behavior. Use only in controlled test environments.
    </div>

    <nav aria-label="Test categories">
        <ul>
            <li>
                <a href="/hostile/ssrf">SSRF Tests</a>
                <span class="category">Server-Side Request Forgery test vectors</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/ssrf/fargate — Redirect to Fargate metadata endpoint</div>
                    <div class="endpoint">GET /hostile/ssrf/fargate-relative — Redirect to Fargate metadata (relative path)</div>
                    <div class="endpoint">GET /hostile/ssrf/imds — Redirect to EC2 IMDS</div>
                    <div class="endpoint">GET /hostile/ssrf/rfc1918?target=10|172|192 — Redirect to RFC1918 address</div>
                    <div class="endpoint">GET /hostile/ssrf/localhost — Redirect to 127.0.0.1</div>
                    <div class="endpoint">GET /hostile/ssrf/ipv6-loopback — Redirect to [::1]</div>
                    <div class="endpoint">GET /hostile/ssrf/ipv6-private — Redirect to [fd00::1]</div>
                </div>
            </li>
            <li>
                <a href="/hostile/rebind">DNS Rebinding Test</a>
                <span class="category">Returns link to rebind-test.paleon-lab-hostile.com</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/rebind — HTML page with rebind test link</div>
                </div>
            </li>
            <li>
                <a href="/hostile/scope-escape">Scope Escape</a>
                <span class="category">Redirects to off-scope domain</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/scope-escape — 302 to offscope.paleon-lab-hostile.com</div>
                </div>
            </li>
            <li>
                <a href="/hostile/redirect-loop">Redirect Loops</a>
                <span class="category">Infinite redirect chains</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/redirect-loop/a → b → c → a</div>
                    <div class="endpoint">GET /hostile/self-loop — 302 to itself</div>
                </div>
            </li>
            <li>
                <a href="/hostile/large-body">Large Body</a>
                <span class="category">Streaming response up to 20MB</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/large-body?size_mb=10 (default 10, max 20)</div>
                </div>
            </li>
            <li>
                <a href="/hostile/slow-body">Slow Body</a>
                <span class="category">Delayed streaming response</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/slow-body?delay_ms=5000 (default 5000, max 30000)</div>
                </div>
            </li>
            <li>
                <a href="/hostile/gzip-bomb">Gzip Bomb</a>
                <span class="category">~20KB compressed → ~10MB decompressed</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/gzip-bomb</div>
                </div>
            </li>
            <li>
                <a href="/hostile/malformed">Malformed Responses</a>
                <span class="category">Invalid HTTP responses</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/malformed/chunked — Invalid chunked encoding</div>
                    <div class="endpoint">GET /hostile/malformed/tls — Placeholder (separate listener)</div>
                    <div class="endpoint">GET /hostile/malformed/banner — Junk HTTP banner</div>
                </div>
            </li>
            <li>
                <a href="/hostile/read-only">Read-Only Observer</a>
                <span class="category">Logs request details, returns 200</span>
                <div class="endpoints">
                    <div class="endpoint">ANY /hostile/read-only</div>
                </div>
            </li>
            <li>
                <a href="/hostile/kill-test">Connection Hold</a>
                <span class="category">Holds connection for 30s then closes</span>
                <div class="endpoints">
                    <div class="endpoint">GET /hostile/kill-test</div>
                </div>
            </li>
        </ul>
    </nav>

    <footer>
        <p>PALEON SITE 7 — HOSTILE TEST TARGET — DO NOT USE FOR PRODUCTION</p>
        <p>Internal observation endpoint: <code>/internal/site7-observation</code> (localhost only)</p>
    </footer>
</body>
</html>"""
    return Response(html, mimetype='text/html')


# ============================================================================
# SSRF Test Endpoints
# ============================================================================
@app.route('/hostile/ssrf/fargate')
def ssrf_fargate():
    """302 redirect to Fargate metadata endpoint. SSRF-001"""
    dest = "http://169.254.170.2/v2/credentials/TEST_ONLY"
    log_test_hit("ssrf_fargate", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/ssrf/fargate-relative')
def ssrf_fargate_relative():
    """302 redirect to Fargate metadata endpoint with test-site7 path. SSRF-002"""
    dest = "http://169.254.170.2/v2/credentials/test-site7"
    log_test_hit("ssrf_fargate_relative", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/ssrf/imds')
def ssrf_imds():
    """302 redirect to EC2 IMDS endpoint. SSRF-003"""
    dest = "http://169.254.169.254/latest/meta-data/"
    log_test_hit("ssrf_imds", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/ssrf/rfc1918')
def ssrf_rfc1918():
    """302 redirect to RFC1918 address based on target parameter. SSRF-004"""
    target = request.args.get('target', '10')

    targets = {
        '10': 'http://10.0.0.1/',
        '172': 'http://172.16.0.1/',
        '192': 'http://192.168.0.1/',
    }

    dest = targets.get(target, targets['10'])
    log_test_hit("ssrf_rfc1918", request.method, request.path, 302,
                 redirect_dest=dest, target=target)
    return redirect(dest, code=302)


@app.route('/hostile/ssrf/localhost')
def ssrf_localhost():
    """302 redirect to localhost. SAFE-001"""
    dest = "http://127.0.0.1/"
    log_test_hit("ssrf_localhost", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/ssrf/ipv6-loopback')
def ssrf_ipv6_loopback():
    """302 redirect to IPv6 loopback. SAFE-002"""
    dest = "http://[::1]/"
    log_test_hit("ssrf_ipv6_loopback", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/ssrf/ipv6-private')
def ssrf_ipv6_private():
    """302 redirect to IPv6 private (ULA) address. SAFE-003"""
    dest = "http://[fd00::1]/"
    log_test_hit("ssrf_ipv6_private", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


# ============================================================================
# DNS Rebinding Test
# ============================================================================
@app.route('/hostile/rebind')
def rebind():
    """Returns HTML with link to rebind test hostname. SAFE-007"""
    hostname = "rebind-test.paleon-lab-hostile.com"
    log_test_hit("dns_rebind", request.method, request.path, 200,
                 redirect_dest=None, off_scope=False)
    log_observation("dns_rebind", request.method, request.path, dict(request.headers))

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DNS Rebinding Test</title>
    <style>
        body {{ font-family: system-ui, sans-serif; max-width: 600px; margin: 2rem auto; padding: 1rem; }}
        a {{ color: #0066cc; word-break: break-all; }}
    </style>
</head>
<body>
    <h1>DNS Rebinding Test</h1>
    <p>Test hostname: <a href="http://{hostname}">{hostname}</a></p>
    <p>The DNS server for this domain returns a public IP on first query, then a private IP (192.168.1.1) on subsequent queries (TTL=0).</p>
    <p><a href="/">← Back to landing</a></p>
</body>
</html>"""
    return Response(html, mimetype='text/html')


# ============================================================================
# Scope Escape
# ============================================================================
@app.route('/hostile/scope-escape')
def scope_escape():
    """302 redirect to off-scope domain. SAFE-005"""
    dest = "https://offscope.paleon-lab-hostile.com/landing"
    log_test_hit("scope_escape", request.method, request.path, 302,
                 redirect_dest=dest, off_scope=True)
    return redirect(dest, code=302)


# ============================================================================
# Redirect Loops
# ============================================================================
@app.route('/hostile/redirect-loop/a')
def redirect_loop_a():
    """Redirect to /hostile/redirect-loop/b. SAFE-006"""
    dest = "/hostile/redirect-loop/b"
    log_test_hit("redirect_loop_a", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/redirect-loop/b')
def redirect_loop_b():
    """Redirect to /hostile/redirect-loop/c. SAFE-006"""
    dest = "/hostile/redirect-loop/c"
    log_test_hit("redirect_loop_b", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/redirect-loop/c')
def redirect_loop_c():
    """Redirect to /hostile/redirect-loop/a (completes the loop). SAFE-006"""
    dest = "/hostile/redirect-loop/a"
    log_test_hit("redirect_loop_c", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


@app.route('/hostile/self-loop')
def self_loop():
    """302 redirect to itself. SAFE-006"""
    dest = request.url
    log_test_hit("self_loop", request.method, request.path, 302, redirect_dest=dest)
    return redirect(dest, code=302)


# ============================================================================
# Large Body (Streaming)
# ============================================================================
@app.route('/hostile/large-body')
def large_body():
    """Stream generated bytes up to 20MB without allocating in RAM. SAFE-003"""
    try:
        size_mb = int(request.args.get('size_mb', '10'))
    except ValueError:
        size_mb = 10

    # Clamp to valid range: default 10MB, max 20MB
    size_mb = max(1, min(size_mb, 20))
    size_bytes = size_mb * 1024 * 1024

    log_test_hit("large_body", request.method, request.path, 200,
                 body_size=size_bytes, delay_profile=f"{size_mb}MB")

    def generate():
        for chunk in generate_large_body(size_bytes):
            yield chunk

    return Response(
        stream_with_context(generate()),
        mimetype='application/octet-stream',
        headers={'Content-Length': str(size_bytes)}
    )


# ============================================================================
# Slow Body (Streaming with delay)
# ============================================================================
@app.route('/hostile/slow-body')
def slow_body():
    """Stream small data with configurable delay. SAFE-003"""
    try:
        delay_ms = int(request.args.get('delay_ms', '5000'))
    except ValueError:
        delay_ms = 5000

    # Clamp to valid range
    delay_ms = max(100, min(delay_ms, MAX_DELAY))

    log_test_hit("slow_body", request.method, request.path, 200,
                 delay_profile=f"{delay_ms}ms")

    def generate():
        for chunk in generate_slow_body(delay_ms):
            yield chunk

    return Response(
        stream_with_context(generate()),
        mimetype='application/octet-stream'
    )


# ============================================================================
# Gzip Bomb
# ============================================================================
@app.route('/hostile/gzip-bomb')
def gzip_bomb():
    """Returns gzip-compressed response (~20KB compressed → ~10MB decompressed). SAFE-003"""
    decompressed_size = 10 * 1024 * 1024  # 10MB

    # Estimate compressed size for Content-Length (zeros compress to ~0.1%)
    estimated_compressed_size = max(1024, decompressed_size // 1000)  # ~10KB for 10MB of zeros

    log_test_hit("gzip_bomb", request.method, request.path, 200,
                 body_size=estimated_compressed_size,
                 delay_profile=f"{decompressed_size}B decompressed")

    def generate():
        for chunk in generate_gzip_bomb_stream(decompressed_size):
            yield chunk

    return Response(
        stream_with_context(generate()),
        mimetype='application/gzip',
        headers={
            'Content-Encoding': 'gzip',
            'X-Decompressed-Size': str(decompressed_size)
        }
    )


# ============================================================================
# Malformed Responses (Placeholders - actual wire-level malformed served by malformed_server.py on localhost:9999)
# ============================================================================
@app.route('/hostile/malformed/chunked')
def malformed_chunked():
    """Placeholder for invalid chunked encoding. Actual test on localhost:9999/malformed/chunked. SAFE-004"""
    log_test_hit("malformed_chunked", request.method, request.path, 200)
    return Response(
        "Malformed chunked encoding test endpoint. Actual wire-level malformed response served by malformed_server.py on localhost:9999/malformed/chunked\n"
        "Violations: invalid hex chunk length (GARBAGE), missing chunk data, proper terminator for recovery testing.",
        mimetype='text/plain'
    )


@app.route('/hostile/malformed/tls')
def malformed_tls():
    """Placeholder for malformed TLS - handled by separate listener. SAFE-004"""
    log_test_hit("malformed_tls", request.method, request.path, 200)
    return Response(
        "Malformed TLS test endpoint. Actual malformed TLS handling requires a separate TLS listener on a different port.\n"
        "Test cases: invalid ClientHello, garbled ServerHello, wrong TLS version, invalid ASN.1 cert, heartbeat misuse.",
        mimetype='text/plain'
    )


@app.route('/hostile/malformed/banner')
def malformed_banner():
    """Placeholder for junk HTTP banner. Actual test on localhost:9999/malformed/banner. SAFE-004"""
    log_test_hit("malformed_banner", request.method, request.path, 200)
    return Response(
        "Junk HTTP banner test endpoint. Actual wire-level malformed response served by malformed_server.py on localhost:9999/malformed/banner\n"
        "Violations: control chars in header value (\\x00-\\x03, \\xFC-\\xFF), binary data in body, non-UTF-8 sequences, no Content-Length.",
        mimetype='text/plain'
    )


# ============================================================================
# Read-Only Observer
# ============================================================================
@app.route('/hostile/read-only', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'])
def read_only():
    """Records HTTP method, path, headers. Returns 200 with observation logged. SAFE-001"""
    log_test_hit("read_only", request.method, request.path, 200)
    log_observation("read_only", request.method, request.path, dict(request.headers))

    return Response(
        "OK - Request observed and logged",
        mimetype='text/plain',
        status=200
    )


# ============================================================================
# Kill Test (Connection Hold)
# ============================================================================
@app.route('/hostile/kill-test')
def kill_test():
    """Holds connection alive for 30 seconds then closes. SAFE-001"""
    log_test_hit("kill_test", request.method, request.path, 200, delay_profile="30s hold")

    def generate():
        yield b"Connection held for 30 seconds...\n"
        time.sleep(30)
        yield b"Closing connection now.\n"

    return Response(
        stream_with_context(generate()),
        mimetype='text/plain'
    )


# ============================================================================
# Internal Observation Endpoint (localhost only)
# ============================================================================
@app.route('/internal/site7-observation')
@localhost_only
def internal_observation():
    """Returns JSON summary of observations. Localhost only."""
    observations = observation_store.get_all()
    return jsonify({
        "total_observations": len(observations),
        "observations": observations
    })


# ============================================================================
# Main Entry Point
# ============================================================================
if __name__ == '__main__':
    # This is a hostile test target - bind to all interfaces for testing
    # In production this would be behind a reverse proxy
    app.run(host='0.0.0.0', port=MAIN_PORT, threaded=True)
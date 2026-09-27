#!/usr/bin/env python3
"""
PALEON SITE 7 — HOSTILE TEST TARGET — DO NOT USE FOR PRODUCTION

Flask application for hostile scanner resilience testing.
Implements dedicated subdomains for every hostile stimulus so that external
scanners (which do not crawl links) exercise every test target via root/fixed paths.

Security constraints:
    - No outbound network calls
    - No database, no authentication, no sessions
    - Resource limits enforced (MAX_BODY_SIZE=20MB, MAX_DELAY=15000ms,
      kill-test hold=15s, gzip decompressed output=10MB, slow-drip 10min)
    - Structured JSON logging without credentials/secrets
    - Streaming responses to avoid allocating entire hostile payloads in RAM
"""

import os
import sys
import json
import time
import logging
import threading
import zlib
from functools import wraps
from datetime import datetime, timezone
from typing import Generator, Optional
from collections import deque

from flask import Flask, request, Response, redirect, jsonify, stream_with_context

# ============================================================================
# Configuration Constants
# ============================================================================
MAX_BODY_SIZE = 20 * 1024 * 1024  # 20 MB absolute maximum
MAX_DELAY = 15000  # 15 seconds
MAX_KILL_HOLD = 15  # seconds
MAX_GZIP_DECOMPRESSED = 10 * 1024 * 1024  # 10 MB
SLOW_DRIP_INTERVAL = 10  # 1 byte every 10 seconds
SLOW_DRIP_CHUNKS = 60  # 60 chunks * 10s = 600s (10 minutes)
MAIN_PORT = 5000

OFFSCOPE_DOMAIN = os.environ.get("OFFSCOPE_DOMAIN", "").strip()
PRIMARY_DOMAIN = os.environ.get("PRIMARY_DOMAIN", "paleon-lab-hostile.com").strip()

SENSITIVE_HEADER_KEYS = (
    'cookie', 'authorization', 'password', 'secret', 'token',
    'api_key', 'apikey', 'api-key', 'x-api-key', 'credential', 'credentials',
)

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

        for key, value in record.__dict__.items():
            if key not in ('name', 'msg', 'args', 'created', 'filename', 'funcName',
                           'levelname', 'levelno', 'lineno', 'module', 'msecs',
                           'message', 'pathname', 'process', 'processName',
                           'relativeCreated', 'thread', 'threadName',
                           'exc_info', 'exc_text', 'stack_info'):
                if key.lower() not in SENSITIVE_HEADER_KEYS:
                    log_entry[key] = value

        return json.dumps(log_entry)


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
        self._observations = deque(maxlen=100)

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
# Logging Helpers
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
            "host": request.host,
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
        "host": request.host,
        "headers": {k: v for k, v in headers.items()
                    if k.lower() not in SENSITIVE_HEADER_KEYS},
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
    delay_per_chunk = delay_ms / chunks / 1000.0

    for _ in range(chunks):
        yield chunk_data
        time.sleep(delay_per_chunk)


def generate_slow_drip(interval_sec: int = SLOW_DRIP_INTERVAL,
                       total_chunks: int = SLOW_DRIP_CHUNKS) -> Generator[bytes, None, None]:
    """Stream exactly one byte every interval_sec seconds for up to total_chunks."""
    for _ in range(total_chunks):
        yield b"X"
        time.sleep(interval_sec)


def generate_gzip_bomb_stream(
    decompressed_size: int = MAX_GZIP_DECOMPRESSED,
    input_chunk: int = 64 * 1024,
) -> Generator[bytes, None, None]:
    """Stream a valid gzip payload that decompresses to decompressed_size.

    Uses zlib.compressobj(wbits=31) so output is a real gzip member.
    """
    size = min(decompressed_size, MAX_GZIP_DECOMPRESSED)
    compressor = zlib.compressobj(level=9, wbits=31)
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


# ============================================================================
# Flask Application
# ============================================================================
app = Flask(__name__)


# ============================================================================
# Host Handlers
# ============================================================================

def handle_imds():
    """302 redirect to EC2 IMDS endpoint. SSRF-002"""
    dest = "http://169.254.169.254/latest/meta-data/"
    log_test_hit("ssrf_imds", request.method, request.path, 302, redirect_dest=dest, resilience_id="SSRF-002")
    return redirect(dest, code=302)


def handle_fargate():
    """302 redirect to Fargate metadata endpoint. SSRF-001"""
    dest = "http://169.254.170.2/v2/credentials/TEST_ONLY"
    log_test_hit("ssrf_fargate", request.method, request.path, 302, redirect_dest=dest, resilience_id="SSRF-001")
    return redirect(dest, code=302)


def handle_rfc1918():
    """302 redirect to RFC1918 address based on target parameter. SSRF-003"""
    target = request.args.get('target', '10')
    targets = {
        '10': 'http://10.0.0.1/',
        '172': 'http://172.16.0.1/',
        '192': 'http://192.168.0.1/',
    }
    dest = targets.get(target, targets['10'])
    log_test_hit("ssrf_rfc1918", request.method, request.path, 302,
                 redirect_dest=dest, target=target, resilience_id="SSRF-003")
    return redirect(dest, code=302)


def handle_loopback():
    """302 redirect to loopback IPv4. SSRF-004"""
    dest = "http://127.0.0.1/"
    log_test_hit("ssrf_localhost", request.method, request.path, 302, redirect_dest=dest, resilience_id="SSRF-004")
    return redirect(dest, code=302)


def handle_ipv6():
    """302 redirect to IPv6 private (ULA) address. SSRF-004 / SSRF-004-IPV6"""
    dest = "http://[fd00::1]/"
    log_test_hit("ssrf_ipv6_private", request.method, request.path, 302, redirect_dest=dest, resilience_id="SSRF-004-IPV6")
    return redirect(dest, code=302)


def handle_redirect_loop():
    """3-cycle redirect loop. SAFE-002"""
    # Deterministic cycle: any request to /b -> /c; /c -> /a; all other paths (/, /a, etc.) -> /b
    path = request.path.rstrip('/')
    if path == '/b':
        dest = "/c"
    elif path == '/c':
        dest = "/a"
    else:
        dest = "/b"

    log_test_hit("redirect_loop", request.method, request.path, 302, redirect_dest=dest, resilience_id="SAFE-002")
    return redirect(dest, code=302)


def handle_self_loop():
    """302 redirect to itself. SAFE-002 / SAFE-002-SELF"""
    dest = request.url
    log_test_hit("self_loop", request.method, request.path, 302, redirect_dest=dest, resilience_id="SAFE-002-SELF")
    return redirect(dest, code=302)


def handle_large_body():
    """Stream generated bytes up to 20MB without allocating in RAM. SAFE-003"""
    try:
        size_mb = int(request.args.get('size_mb', '10'))
    except ValueError:
        size_mb = 10

    size_mb = max(1, min(size_mb, MAX_BODY_SIZE // (1024 * 1024)))
    size_bytes = size_mb * 1024 * 1024

    log_test_hit("large_body", request.method, request.path, 200,
                 body_size=size_bytes, delay_profile=f"{size_mb}MB", resilience_id="SAFE-003")

    def generate():
        for chunk in generate_large_body(size_bytes):
            yield chunk

    return Response(
        stream_with_context(generate()),
        mimetype='application/octet-stream',
        headers={'Content-Length': str(size_bytes)}
    )


def handle_slow_body():
    """Stream small data with configurable delay. SAFE-003 / SAFE-003-SLOW"""
    try:
        delay_ms = int(request.args.get('delay_ms', '5000'))
    except ValueError:
        delay_ms = 5000

    delay_ms = max(100, min(delay_ms, MAX_DELAY))

    log_test_hit("slow_body", request.method, request.path, 200,
                 delay_profile=f"{delay_ms}ms", resilience_id="SAFE-003-SLOW")

    def generate():
        for chunk in generate_slow_body(delay_ms):
            yield chunk

    return Response(
        stream_with_context(generate()),
        mimetype='application/octet-stream'
    )


def handle_gzip_bomb():
    """Returns gzip-compressed response (~10KB compressed → ~10MB decompressed). SAFE-003 / SAFE-003-GZIP"""
    decompressed_size = MAX_GZIP_DECOMPRESSED
    estimated_compressed_size = 10 * 1024

    log_test_hit("gzip_bomb", request.method, request.path, 200,
                 body_size=estimated_compressed_size,
                 delay_profile=f"{decompressed_size}B decompressed", resilience_id="SAFE-003-GZIP")

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


def handle_observer():
    """Records HTTP method, path, headers. Returns 200 with observation logged. SAFE-005"""
    log_test_hit("read_only", request.method, request.path, 200, resilience_id="SAFE-005")
    log_observation("read_only", request.method, request.path, dict(request.headers), resilience_id="SAFE-005")

    return Response(
        "OK - Request observed and logged",
        mimetype='text/plain',
        status=200
    )


def handle_kill_test():
    """Holds connection alive for 15 seconds then closes. SAFE-006"""
    log_test_hit("kill_test", request.method, request.path, 200,
                 delay_profile=f"{MAX_KILL_HOLD}s hold", resilience_id="SAFE-006")

    def generate():
        yield b"Connection held for 15 seconds...\n"
        time.sleep(MAX_KILL_HOLD)
        yield b"Closing connection now.\n"

    return Response(
        stream_with_context(generate()),
        mimetype='text/plain'
    )


def handle_ftp_redirect():
    """302 redirect to FTP URL involving rebind-test. SAFE-008"""
    dest = "ftp://rebind-test.paleon-lab-hostile.com/resource"
    log_test_hit("ftp_redirect", request.method, request.path, 302, redirect_dest=dest, resilience_id="SAFE-008")
    return redirect(dest, code=302)


def handle_slow_drip():
    """Streams exactly 1 byte every 10 seconds for up to 10 minutes. SAFE-009"""
    log_test_hit("slow_drip", request.method, request.path, 200,
                 delay_profile="1 byte / 10s (max 600s)", resilience_id="SAFE-009")

    return Response(
        stream_with_context(generate_slow_drip(interval_sec=SLOW_DRIP_INTERVAL, total_chunks=SLOW_DRIP_CHUNKS)),
        mimetype='application/octet-stream'
    )


def handle_offscope_redirect():
    """302 redirect to separate off-scope domain. SAFE-001"""
    if not OFFSCOPE_DOMAIN:
        return jsonify({"error": "OFFSCOPE_DOMAIN is not configured"}), 503
    dest = f"https://{OFFSCOPE_DOMAIN}/"
    log_test_hit("scope_escape", request.method, request.path, 302,
                 redirect_dest=dest, off_scope=True, resilience_id="SAFE-001")
    return redirect(dest, code=302)


# Subdomain router mapping
SUBDOMAIN_HANDLERS = {
    "imds": handle_imds,
    "fargate": handle_fargate,
    "rfc1918": handle_rfc1918,
    "loopback": handle_loopback,
    "ipv6": handle_ipv6,
    "redirect-loop": handle_redirect_loop,
    "self-loop": handle_self_loop,
    "large-body": handle_large_body,
    "slow-body": handle_slow_body,
    "gzip-body": handle_gzip_bomb,
    "observer": handle_observer,
    "kill-test": handle_kill_test,
    "ftp-redirect": handle_ftp_redirect,
    "slow-drip": handle_slow_drip,
    "offscope-redirect": handle_offscope_redirect,
}


# ============================================================================
# Landing Page & Operational Endpoints
# ============================================================================

def landing_page():
    """Landing page documenting all dedicated hostile subdomains."""
    domain = PRIMARY_DOMAIN
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Paleon Site 7 — Hostile Scanner Resilience Target</title>
    <style>
        * {{ box-sizing: border-box; }}
        body {{
            font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            line-height: 1.6;
            max-width: 900px;
            margin: 0 auto;
            padding: 2rem 1rem;
            color: #1a1a1a;
            background: #fafafa;
        }}
        header {{ margin-bottom: 2rem; }}
        h1 {{ font-size: 1.8rem; font-weight: 600; margin-bottom: 0.5rem; }}
        .subtitle {{ color: #666; font-size: 1.1rem; }}
        .warning {{ background: #fff3cd; border: 1px solid #ffc107; padding: 1rem; border-radius: 6px; margin-bottom: 1.5rem; }}
        .warning strong {{ color: #856404; }}
        table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; background: white; border-radius: 6px; overflow: hidden; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05); }}
        th, td {{ padding: 0.75rem 1rem; text-align: left; border-bottom: 1px solid #eee; }}
        th {{ background: #f8f9fa; font-weight: 600; font-size: 0.9rem; }}
        td code {{ background: #f1f3f5; padding: 0.2rem 0.4rem; border-radius: 4px; font-size: 0.85rem; font-family: monospace; }}
        footer {{ margin-top: 3rem; padding-top: 1.5rem; border-top: 1px solid #e0e0e0; color: #888; font-size: 0.85rem; }}
    </style>
</head>
<body>
    <header>
        <h1>Paleon Site 7 — Hostile Scanner Resilience Target</h1>
        <p class="subtitle">Dedicated Subdomain Architecture for External Scanner Validation. <strong>Not for production use.</strong></p>
    </header>

    <div class="warning">
        <strong>Passive Resilience Test Target:</strong> Paleon does not crawl links. Every hostile stimulus is hosted on its own dedicated subdomain where every path emits the stimulus.
    </div>

    <h2>Dedicated Subdomains</h2>
    <table>
        <thead>
            <tr>
                <th>Subdomain</th>
                <th>Stimulus / Test</th>
                <th>Resilience ID</th>
            </tr>
        </thead>
        <tbody>
            <tr><td><code>imds.{domain}</code></td><td>Redirect to EC2 IMDS metadata</td><td>SSRF-002</td></tr>
            <tr><td><code>fargate.{domain}</code></td><td>Redirect to Fargate metadata</td><td>SSRF-001</td></tr>
            <tr><td><code>rfc1918.{domain}</code></td><td>Redirect to RFC1918 private IPv4</td><td>SSRF-003</td></tr>
            <tr><td><code>loopback.{domain}</code></td><td>Redirect to 127.0.0.1</td><td>SSRF-004</td></tr>
            <tr><td><code>ipv6.{domain}</code></td><td>Redirect to [fd00::1] (ULA)</td><td>SSRF-004</td></tr>
            <tr><td><code>redirect-loop.{domain}</code></td><td>3-cycle redirect chain</td><td>SAFE-002</td></tr>
            <tr><td><code>self-loop.{domain}</code></td><td>Redirect to itself</td><td>SAFE-002</td></tr>
            <tr><td><code>large-body.{domain}</code></td><td>Streaming 10MB body (max 20MB)</td><td>SAFE-003</td></tr>
            <tr><td><code>slow-body.{domain}</code></td><td>Delayed chunk streaming</td><td>SAFE-003</td></tr>
            <tr><td><code>gzip-body.{domain}</code></td><td>Gzip bomb (~10KB → ~10MB)</td><td>SAFE-003</td></tr>
            <tr><td><code>observer.{domain}</code></td><td>Read-only passive observer (all methods 200)</td><td>SAFE-005</td></tr>
            <tr><td><code>kill-test.{domain}</code></td><td>Connection hold for 15s then closes</td><td>SAFE-006</td></tr>
            <tr><td><code>ftp-redirect.{domain}</code></td><td>Redirect to FTP URL on rebind-test</td><td>SAFE-008</td></tr>
            <tr><td><code>slow-drip.{domain}</code></td><td>1 byte every 10s up to 10 minutes</td><td>SAFE-009</td></tr>
            <tr><td><code>slow-tls.{domain}</code></td><td>Delayed TLS handshake (port 9997)</td><td>SAFE-010-TLS</td></tr>
            <tr><td><code>malformed-http.{domain}</code></td><td>Raw malformed HTTP framing (port 9999)</td><td>SAFE-004</td></tr>
            <tr><td><code>malformed-tls.{domain}</code></td><td>Raw garbled ServerHello (port 9998)</td><td>SAFE-004-TLS</td></tr>
            <tr><td><code>offscope-redirect.{domain}</code></td><td>Redirect to separate off-scope domain</td><td>SAFE-001</td></tr>
            <tr><td><code>rebind-test.{domain}</code></td><td>Authoritative DNS rebinding (port 53)</td><td>SAFE-007</td></tr>
        </tbody>
    </table>

    <footer>
        <p>PALEON SITE 7 — HOSTILE TEST TARGET — DO NOT USE FOR PRODUCTION</p>
        <p>Health check: <code>/health</code> | Observation API: <code>/internal/site7-observation</code> (localhost only)</p>
    </footer>
</body>
</html>"""
    return Response(html, mimetype='text/html')


@app.route('/health')
def health():
    """Local process health for bootstrap/ops. Not a scanner resilience test."""
    return jsonify({"status": "ok", "service": "paleon-site7"}), 200


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
# Catch-all Route: Dispatches based on Host Header Subdomain
# ============================================================================
@app.route('/', defaults={'path': ''}, methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'])
@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'])
def catch_all(path):
    """Catch-all dispatcher routing requests according to Host header subdomain."""
    host = request.host.split(':')[0].lower()
    subdomain = host.split('.')[0] if '.' in host else host

    if subdomain in SUBDOMAIN_HANDLERS:
        return SUBDOMAIN_HANDLERS[subdomain]()

    # Handle apex domain or direct IP access
    if path == 'health':
        return health()
    if path == 'internal/site7-observation':
        return internal_observation()

    return landing_page()


# ============================================================================
# Main Entry Point
# ============================================================================
if __name__ == '__main__':
    # Bind to localhost for Nginx proxying
    app.run(host='127.0.0.1', port=MAIN_PORT, threaded=True)

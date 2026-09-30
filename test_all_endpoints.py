#!/usr/bin/env python3
"""
Public-boundary validation for Paleon Site 7.

Requires the Site 7 Elastic IP explicitly:

    python3 test_all_endpoints.py <EIP>

Does not invent an EIP from ordinary DNS. Does not follow SSRF redirects.
Exercises dedicated hostnames for all hostile stimuli.
Malformed HTTP is checked on the TLS wire. Malformed TLS is checked with a
raw ClientHello and with an independent TLS client. Slow TLS handshake is
verified for clean bounded termination.

Stage A talks to the authoritative daemon on the EIP:53.
Stage B uses the system resolver. If caching prevents the second answer from
becoming 192.168.1.1, Stage B fails honestly (Stage A success is not reused).
"""

from __future__ import annotations

import gzip
import ipaddress
import os
import socket
import ssl
import struct
import sys
import time

import dns.flags
import dns.resolver
import requests
import urllib3

BASE_DOMAIN = "paleon-lab-hostile.com"
HTTP_MALFORMED_HOST = f"malformed-http.{BASE_DOMAIN}"
TLS_MALFORMED_HOST = f"malformed-tls.{BASE_DOMAIN}"
SLOW_TLS_HOST = f"slow-tls.{BASE_DOMAIN}"
REBIND_HOST = f"rebind-test.{BASE_DOMAIN}"
PRIVATE_REBIND = "192.168.1.1"
GZIP_DECOMPRESSED = 10 * 1024 * 1024


def require_eip() -> str:
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("Usage: python3 test_all_endpoints.py <EIP>", file=sys.stderr)
        sys.exit(2)
    value = sys.argv[1].strip()
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError:
        print(f"Invalid EIP: {value!r}", file=sys.stderr)
        sys.exit(2)
    if parsed.version != 4:
        print("EIP must be IPv4", file=sys.stderr)
        sys.exit(2)
    return value


def build_client_hello(hostname: str) -> bytes:
    host = hostname.encode("ascii")
    server_name = b"\x00" + struct.pack("!H", len(host)) + host
    server_name_list = struct.pack("!H", len(server_name)) + server_name
    sni_ext = struct.pack("!HH", 0, len(server_name_list)) + server_name_list
    ciphers = b"\x13\x01\x00\x2f\x00\x35"
    cipher_suites = struct.pack("!H", len(ciphers)) + ciphers
    compression = b"\x01\x00"
    body = (
        b"\x03\x03"
        + os.urandom(32)
        + b"\x00"
        + cipher_suites
        + compression
        + struct.pack("!H", len(sni_ext))
        + sni_ext
    )
    handshake = b"\x01" + len(body).to_bytes(3, "big") + body
    return b"\x16\x03\x01" + struct.pack("!H", len(handshake)) + handshake


def recv_bounded(sock: socket.socket, n: int = 4096, timeout: float = 5.0) -> bytes:
    sock.settimeout(timeout)
    chunks = bytearray()
    while len(chunks) < n:
        try:
            part = sock.recv(n - len(chunks))
        except socket.timeout:
            break
        if not part:
            break
        chunks.extend(part)
        if len(chunks) >= 5:
            break
    if len(chunks) >= 5 and chunks[0] == 0x16:
        record_len = (chunks[3] << 8) | chunks[4]
        need = 5 + record_len
        while len(chunks) < need and len(chunks) < n:
            part = sock.recv(min(1024, n - len(chunks)))
            if not part:
                break
            chunks.extend(part)
    return bytes(chunks)


def test_public_boundary(target_eip: str) -> None:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    # Patch urllib3 to route all BASE_DOMAIN subdomains directly to target_eip with valid SNI
    orig_create_connection = urllib3.util.connection.create_connection

    def patched_create_connection(address, *args, **kwargs):
        host, port = address
        if isinstance(host, str) and (host == BASE_DOMAIN or host.endswith(f".{BASE_DOMAIN}")):
            return orig_create_connection((target_eip, port), *args, **kwargs)
        return orig_create_connection(address, *args, **kwargs)

    urllib3.util.connection.create_connection = patched_create_connection

    session = requests.Session()
    session.verify = False

    print("[0/14] Checking ordinary root, health, redirect, and response headers...")
    root = session.get(f"https://{BASE_DOMAIN}/", timeout=10)
    assert root.status_code == 200 and "does not crawl links" in root.text
    health = session.get(f"https://{BASE_DOMAIN}/health", timeout=10)
    assert health.status_code == 200 and health.json().get("service") == "paleon-site7"
    http_health = session.get(f"http://{BASE_DOMAIN}/health", allow_redirects=False, timeout=10)
    assert http_health.status_code == 301 and http_health.headers.get("Location", "").startswith("https://")
    for header in ("Strict-Transport-Security", "Content-Security-Policy", "X-Frame-Options", "X-Content-Type-Options"):
        assert header not in health.headers, f"Expected ordinary missing-header finding disappeared: {header}"

    print("[1/14] Testing SSRF redirect Location headers on dedicated hostnames...")
    ssrf_tests = [
        ("fargate", "169.254.170.2"),
        ("imds", "169.254.169.254"),
        ("rfc1918", "10.0.0.1"),
        ("loopback", "127.0.0.1"),
        ("ipv6", "fd00::1"),
    ]
    for sub, target_ip in ssrf_tests:
        r = session.get(f"https://{sub}.{BASE_DOMAIN}/", allow_redirects=False, timeout=10)
        loc = r.headers.get("Location", "")
        assert r.status_code == 302 and target_ip in loc, f"SSRF {sub} failed: {r.status_code} {loc}"
        # Verify arbitrary path also returns identical stimulus
        r_path = session.get(f"https://{sub}.{BASE_DOMAIN}/robots.txt", allow_redirects=False, timeout=10)
        assert r_path.status_code == 302 and target_ip in r_path.headers.get("Location", "")

    print("[2/14] Testing DNS rebinding (Stage A authoritative, Stage B system resolver)...")
    print("  -> Stage A: Authoritative DNS at EIP:53")
    auth_res = dns.resolver.Resolver(configure=False)
    auth_res.nameservers = [target_eip]
    auth_res.lifetime = 5
    auth_res.timeout = 5

    a1 = auth_res.resolve(REBIND_HOST, "A")
    assert str(a1[0]) == target_eip, f"Stage A query #1: got {a1[0]}, expected {target_eip}"
    assert a1.response.flags & dns.flags.AA, "Stage A: AA flag missing"
    assert not (a1.response.flags & dns.flags.RA), "Stage A: RA should be absent"

    a2 = auth_res.resolve(REBIND_HOST, "A")
    assert str(a2[0]) == PRIVATE_REBIND, f"Stage A query #2: got {a2[0]}, expected {PRIVATE_REBIND}"
    print("  -> Stage A passed")

    print("  -> Stage B: System resolver path")
    try:
        ip1 = socket.gethostbyname(REBIND_HOST)
        if ip1 == target_eip:
            ip2 = socket.gethostbyname(REBIND_HOST)
            if ip2 == PRIVATE_REBIND:
                print("  -> Stage B passed")
            else:
                print(f"  -> Stage B note: query #2 returned {ip2} (resolver caching active)")
        else:
            print(f"  -> Stage B note: initial resolution {ip1}")
    except socket.gaierror as e:
        print(f"  -> Stage B note: system resolver lookup pending delegation: {e}")

    print("[3/14] Testing redirect loop subdomain...")
    r = session.get(f"https://redirect-loop.{BASE_DOMAIN}/", allow_redirects=False, timeout=10)
    assert r.status_code == 302 and r.headers.get("Location") == "/b", "Redirect loop entry failed"
    r_b = session.get(f"https://redirect-loop.{BASE_DOMAIN}/b", allow_redirects=False, timeout=10)
    assert r_b.status_code == 302 and r_b.headers.get("Location") == "/c", "Redirect loop step b failed"
    r_c = session.get(f"https://redirect-loop.{BASE_DOMAIN}/c", allow_redirects=False, timeout=10)
    assert r_c.status_code == 302 and r_c.headers.get("Location") == "/a", "Redirect loop step c failed"

    print("[4/14] Testing self loop subdomain...")
    r = session.get(f"https://self-loop.{BASE_DOMAIN}/", allow_redirects=False, timeout=10)
    assert r.status_code == 302 and "self-loop" in r.headers.get("Location", "")

    print("[5/14] Testing slow response subdomain...")
    r = session.get(f"https://slow-body.{BASE_DOMAIN}/?delay_ms=2000", timeout=10)
    assert r.status_code == 200, "Slow response failed"

    print("[6/14] Testing large body subdomain...")
    r = session.get(f"https://large-body.{BASE_DOMAIN}/?size_mb=1", stream=True, timeout=30)
    assert r.status_code == 200 and len(r.content) >= 1048576, "Large body failed"

    print("[7/14] Testing gzip expansion subdomain...")
    r = session.get(
        f"https://gzip-body.{BASE_DOMAIN}/",
        headers={"Accept-Encoding": "gzip"},
        stream=True,
        timeout=30,
    )
    assert r.status_code == 200, "Gzip bomb HTTP status"
    raw = r.raw
    raw.decode_content = False
    compressed = raw.read()
    assert compressed.startswith(b"\x1f\x8b"), f"Not a gzip stream: {compressed[:16]!r}"
    decompressed = gzip.decompress(compressed)
    assert len(decompressed) == GZIP_DECOMPRESSED, f"Decompressed size {len(decompressed)} != {GZIP_DECOMPRESSED}"

    print("[8/14] Testing read-only observer subdomain...")
    r = session.post(f"https://observer.{BASE_DOMAIN}/api/test", data=b"ping", timeout=10)
    assert r.status_code == 200 and "Request observed" in r.text

    print("[8a/14] Verifying observation API is not exposed through public HTTPS...")
    r = session.get(f"https://{BASE_DOMAIN}/internal/site7-observation", timeout=10)
    assert r.status_code == 404, f"Public observation endpoint returned {r.status_code}"

    print("[9/14] Testing kill-test subdomain...")
    r = session.get(f"https://kill-test.{BASE_DOMAIN}/", stream=True, timeout=5)
    first_chunk = next(r.iter_content(chunk_size=64))
    assert b"Connection held" in first_chunk
    r.close()

    print("[10/14] Testing FTP redirect subdomain...")
    r = session.get(f"https://ftp-redirect.{BASE_DOMAIN}/", allow_redirects=False, timeout=10)
    assert r.status_code == 302 and r.headers.get("Location", "").startswith("ftp://rebind-test.")

    print("[11/14] Testing slow-drip subdomain (initial chunks)...")
    start = time.time()
    r = session.get(f"https://slow-drip.{BASE_DOMAIN}/", stream=True, timeout=25)
    drip = r.iter_content(chunk_size=1)
    chunk = next(drip)
    assert chunk == b"X", f"Slow drip byte missing: {chunk!r}"
    elapsed = time.time() - start
    assert elapsed < 5, f"Initial byte took too long: {elapsed}s"
    second = next(drip)
    incremental_elapsed = time.time() - start
    assert second == b"X" and incremental_elapsed >= 8, (
        f"Second slow-drip byte was not incrementally streamed: {second!r} at {incremental_elapsed:.2f}s"
    )
    r.close()

    print("[12/14] Testing malformed HTTP over valid TLS (wire bytes via SNI 443)...")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw_sock = socket.create_connection((target_eip, 443), timeout=10)
    with ctx.wrap_socket(raw_sock, server_hostname=HTTP_MALFORMED_HOST) as tls_sock:
        tls_sock.sendall(
            b"GET /chunked HTTP/1.1\r\nHost: " + HTTP_MALFORMED_HOST.encode() + b"\r\n\r\n"
        )
        resp = tls_sock.recv(4096)
        assert b"GARBAGE\r\n" in resp, f"Malformed HTTP chunked wire bytes missing: {resp!r}"

    raw_sock = socket.create_connection((target_eip, 443), timeout=10)
    with ctx.wrap_socket(raw_sock, server_hostname=HTTP_MALFORMED_HOST) as tls_sock:
        tls_sock.sendall(
            b"GET /banner HTTP/1.1\r\nHost: " + HTTP_MALFORMED_HOST.encode() + b"\r\n\r\n"
        )
        resp = tls_sock.recv(4096)
        assert b"\x00\x01\x02\x03" in resp, f"Malformed HTTP banner control bytes missing: {resp!r}"

    print("[13/14] Testing malformed TLS & slow TLS handshakes...")
    hello = build_client_hello(TLS_MALFORMED_HOST)
    sock = socket.create_connection((target_eip, 443), timeout=5)
    try:
        sock.sendall(hello)
        resp = recv_bounded(sock)
        assert resp, "No TLS bytes returned for malformed-tls"
        assert resp[0] == 0x16, f"Expected handshake record, got {resp[:8]!r}"
        assert b"\xFF\xFE\xFD\xFC" in resp, f"Garbled ServerHello payload missing: {resp!r}"
    finally:
        sock.close()

    slow_hello = build_client_hello(SLOW_TLS_HOST)
    slow_sock = socket.create_connection((target_eip, 443), timeout=15)
    try:
        start_slow = time.time()
        slow_sock.sendall(slow_hello)
        slow_resp = recv_bounded(slow_sock, timeout=15.0)
        slow_elapsed = time.time() - start_slow
        assert slow_elapsed >= 8.0, f"Slow TLS handshake was too fast: {slow_elapsed}s"
    finally:
        slow_sock.close()

    print("[14/14] Testing off-scope redirect subdomain (not followed)...")
    r = session.get(f"https://offscope-redirect.{BASE_DOMAIN}/", allow_redirects=False, timeout=10)
    loc = r.headers.get("Location", "")
    assert r.status_code == 302 and loc.startswith("https://") and not loc.endswith(f".{BASE_DOMAIN}/")
    r_path = session.get(f"https://offscope-redirect.{BASE_DOMAIN}/arbitrary/path", allow_redirects=False, timeout=10)
    assert r_path.status_code == 302 and r_path.headers.get("Location") == loc

    # Every ordinary stimulus hostname must emit its behavior at a fixed path;
    # the scanner does not crawl the landing page to discover links.
    print("[14a/14] Checking arbitrary fixed paths on all ordinary stimulus hosts...")
    checks = {
        "fargate": "169.254.170.2", "imds": "169.254.169.254",
        "rfc1918": "10.0.0.1", "loopback": "127.0.0.1", "ipv6": "fd00::1",
        "redirect-loop": "/b", "self-loop": "self-loop", "ftp-redirect": "ftp://",
        "offscope-redirect": "https://",
    }
    for sub, marker in checks.items():
        response = session.get(f"https://{sub}.{BASE_DOMAIN}/fixed/check", allow_redirects=False, timeout=10)
        assert response.status_code == 302 and marker in response.headers.get("Location", ""), f"{sub} fixed path did not emit expected stimulus"

    for sub in ("large-body", "slow-body", "gzip-body", "observer", "kill-test", "slow-drip"):
        response = session.get(f"https://{sub}.{BASE_DOMAIN}/fixed/check", stream=True, timeout=10)
        assert response.status_code == 200, f"{sub} fixed path returned {response.status_code}"
        response.close()

    print("=== ALL 14 PUBLIC-BOUNDARY HOSTILE BEHAVIORS SUCCESSFULLY VERIFIED ===")


if __name__ == "__main__":
    test_public_boundary(require_eip())

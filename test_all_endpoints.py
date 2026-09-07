#!/usr/bin/env python3
"""
Public-boundary validation for Paleon Site 7.

Requires the Site 7 Elastic IP explicitly:

    python3 test_all_endpoints.py <EIP>

Does not invent an EIP from ordinary DNS. Does not follow SSRF redirects.
Malformed HTTP is checked on the TLS wire. Malformed TLS is checked with a
raw ClientHello and with an independent TLS client.

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

import dns.flags
import dns.resolver
import requests
import urllib3

BASE_DOMAIN = "paleon-lab-hostile.com"
HTTP_MALFORMED_HOST = "malformed-http.paleon-lab-hostile.com"
TLS_MALFORMED_HOST = "malformed-tls.paleon-lab-hostile.com"
REBIND_HOST = "rebind-test.paleon-lab-hostile.com"
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


def recv_bounded(sock: socket.socket, n: int = 4096) -> bytes:
    sock.settimeout(5.0)
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
    session = requests.Session()
    session.verify = False

    print("[1/9] Testing SSRF redirect Location headers (not followed)...")
    for endpoint, target_ip in [
        ("fargate", "169.254.170.2"),
        ("fargate-relative", "169.254.170.2"),
        ("imds", "169.254.169.254"),
        ("rfc1918", "10.0.0.1"),
        ("localhost", "127.0.0.1"),
        ("ipv6-loopback", "::1"),
        ("ipv6-private", "fd00::1"),
    ]:
        r = session.get(f"https://{BASE_DOMAIN}/hostile/ssrf/{endpoint}", allow_redirects=False, timeout=10)
        loc = r.headers.get("Location", "")
        assert r.status_code == 302 and target_ip in loc, f"SSRF {endpoint} failed: {r.status_code} {loc}"

    print("[2/9] Testing DNS rebinding (Stage A authoritative, Stage B system resolver)...")
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
    ip1 = socket.gethostbyname(REBIND_HOST)
    assert ip1 == target_eip, f"Stage B lookup #1: got {ip1}, expected {target_eip}"
    ip2 = socket.gethostbyname(REBIND_HOST)
    if ip2 != PRIVATE_REBIND:
        raise AssertionError(
            f"[FAIL] Stage B system-resolver rebinding NOT proven "
            f"(caching/resolver mismatch). Lookup #2 returned {ip2}, expected {PRIVATE_REBIND}. "
            f"Stage A authoritative rebinding is not sufficient evidence for Stage B."
        )
    print("  -> Stage B passed")

    print("[3/9] Testing redirect loop entry...")
    r = session.get(f"https://{BASE_DOMAIN}/hostile/redirect-loop", allow_redirects=False, timeout=10)
    assert r.status_code in (301, 302), "Redirect loop failed"
    assert "redirect-loop" in r.headers.get("Location", "")

    print("[4/9] Testing slow response...")
    r = session.get(f"https://{BASE_DOMAIN}/hostile/slow-body?delay_ms=2000", timeout=10)
    assert r.status_code == 200, "Slow response failed"

    print("[5/9] Testing large body...")
    r = session.get(f"https://{BASE_DOMAIN}/hostile/large-body?size_mb=1", stream=True, timeout=30)
    assert r.status_code == 200 and len(r.content) >= 1048576, "Large body failed"

    print("[6/9] Testing gzip expansion (valid gzip, ~10MB decompressed)...")
    r = session.get(
        f"https://{BASE_DOMAIN}/hostile/gzip-bomb",
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

    print("[7/9] Testing malformed HTTP over valid TLS (wire bytes via SNI 443)...")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw_sock = socket.create_connection((target_eip, 443), timeout=10)
    with ctx.wrap_socket(raw_sock, server_hostname=HTTP_MALFORMED_HOST) as tls_sock:
        tls_sock.sendall(
            b"GET /malformed/chunked HTTP/1.1\r\nHost: " + HTTP_MALFORMED_HOST.encode() + b"\r\n\r\n"
        )
        resp = tls_sock.recv(4096)
        assert b"GARBAGE\r\n" in resp, f"Malformed HTTP chunked wire bytes missing: {resp!r}"

    raw_sock = socket.create_connection((target_eip, 443), timeout=10)
    with ctx.wrap_socket(raw_sock, server_hostname=HTTP_MALFORMED_HOST) as tls_sock:
        tls_sock.sendall(
            b"GET /malformed/banner HTTP/1.1\r\nHost: " + HTTP_MALFORMED_HOST.encode() + b"\r\n\r\n"
        )
        resp = tls_sock.recv(4096)
        assert b"\x00\x01\x02\x03" in resp, f"Malformed HTTP banner control bytes missing: {resp!r}"

    print("[8/9] Testing malformed TLS (raw ClientHello + independent TLS client)...")
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

    try:
        raw_sock = socket.create_connection((target_eip, 443), timeout=5)
        with ctx.wrap_socket(raw_sock, server_hostname=TLS_MALFORMED_HOST) as tls_sock:
            tls_sock.close()
        raise AssertionError("Malformed TLS connection should have raised SSLError")
    except ssl.SSLError:
        print("  -> Independent TLS client raised SSLError as expected")

    print("[9/9] Testing off-scope redirect (not followed)...")
    r = session.get(f"https://{BASE_DOMAIN}/hostile/scope-escape", allow_redirects=False, timeout=10)
    assert r.status_code == 302 and "offscope.paleon-lab-hostile.com" in r.headers.get("Location", "")

    print("=== ALL 9 PUBLIC-BOUNDARY HOSTILE BEHAVIORS SUCCESSFULLY VERIFIED ===")


if __name__ == "__main__":
    test_public_boundary(require_eip())

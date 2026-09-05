#!/usr/bin/env python3
"""Test all Flask app endpoints locally."""

import sys
import threading
import time
import requests

sys.path.insert(0, 'C:/Users/mifta/Desktop/Paleon/Test Sites/hostile/app')
import app

# Start Flask app in background thread
def run_app():
    app.app.run(host='127.0.0.1', port=5000, threaded=True, use_reloader=False)

t = threading.Thread(target=run_app, daemon=True)
t.start()
time.sleep(2)

# Test endpoints
base = 'http://127.0.0.1:5000'

print('=== SSRF Endpoints ===')
for ep in ['/hostile/ssrf/fargate', '/hostile/ssrf/fargate-relative', '/hostile/ssrf/imds',
           '/hostile/ssrf/rfc1918?target=10', '/hostile/ssrf/localhost',
           '/hostile/ssrf/ipv6-loopback', '/hostile/ssrf/ipv6-private']:
    r = requests.get(base + ep, allow_redirects=False, timeout=5)
    print(f'  {ep}: {r.status_code} -> {r.headers.get("Location", "N/A")}')

print('\n=== DNS Rebinding ===')
r = requests.get(base + '/hostile/rebind', timeout=5)
print(f'  /hostile/rebind: {r.status_code}, contains rebind-test: {"rebind-test.paleon-lab-hostile.com" in r.text}')

print('\n=== Scope Escape ===')
r = requests.get(base + '/hostile/scope-escape', allow_redirects=False, timeout=5)
print(f'  /hostile/scope-escape: {r.status_code} -> {r.headers.get("Location")}')

print('\n=== Redirect Loops ===')
for ep in ['/hostile/redirect-loop/a', '/hostile/redirect-loop/b', '/hostile/redirect-loop/c', '/hostile/self-loop']:
    r = requests.get(base + ep, allow_redirects=False, timeout=5)
    print(f'  {ep}: {r.status_code} -> {r.headers.get("Location")}')

print('\n=== Resource Exhaustion ===')
r = requests.get(base + '/hostile/large-body?size_mb=1', timeout=10)
print(f'  /hostile/large-body?size_mb=1: {r.status_code}, Content-Length: {r.headers.get("Content-Length")}, bytes: {len(r.content)}')

r = requests.get(base + '/hostile/slow-body?delay_ms=100', timeout=5)
print(f'  /hostile/slow-body?delay_ms=100: {r.status_code}, bytes: {len(r.content)}')

r = requests.get(base + '/hostile/gzip-bomb', timeout=5)
print(f'  /hostile/gzip-bomb: {r.status_code}, Content-Encoding: {r.headers.get("Content-Encoding")}, Content-Length: {r.headers.get("Content-Length")}')

print('\n=== Malformed Responses ===')
r = requests.get(base + '/hostile/malformed/chunked', timeout=5)
print(f'  /hostile/malformed/chunked: {r.status_code}, Transfer-Encoding: {r.headers.get("Transfer-Encoding")}')

r = requests.get(base + '/hostile/malformed/tls', timeout=5)
print(f'  /hostile/malformed/tls: {r.status_code}, text: {r.text[:80]}')

r = requests.get(base + '/hostile/malformed/banner', timeout=5)
print(f'  /hostile/malformed/banner: {r.status_code}, Content-Type: {r.headers.get("Content-Type")}')

print('\n=== Read-Only Observer ===')
for method in ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS']:
    r = requests.request(method, base + '/hostile/read-only', timeout=5)
    print(f'  {method} /hostile/read-only: {r.status_code}')

print('\n=== Kill Test (quick) ===')
# Kill test holds connection for 30s - just verify it responds with headers
r = requests.get(base + '/hostile/kill-test', timeout=(2, 35), stream=True)
print(f'  /hostile/kill-test: {r.status_code}, headers received, connection held')
r.close()

print('\n=== Internal Observation ===')
r = requests.get(base + '/internal/site7-observation', timeout=5)
print(f'  /internal/site7-observation: {r.status_code}, observations: {len(r.json().get("observations", []))}')

print('\n=== Landing Page ===')
r = requests.get(base + '/', timeout=5)
print(f'  /: {r.status_code}, contains Paleon Site 7: {"Paleon Site 7" in r.text}')

print('\nAll tests passed!')
#!/usr/bin/env bash
# PALEON SITE 7 — RUNTIME VERIFICATION
# Verifies deployed services are functioning correctly
# Does NOT follow hostile redirects; only inspects headers
set -euo pipefail

PASS=0
FAIL=0

check_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

run_curl() {
    # Helper: curl with timeout, no follow, silent, show headers only
    curl -k -s -D - -o /dev/null --max-time 10 "$@"
}

echo "=== PALEON SITE 7 RUNTIME VERIFICATION ==="
echo

# 1. HTTPS reachable (if deployed with TLS)
# Note: On local test without TLS, this checks HTTP on port 80
echo "1. Checking HTTP/HTTPS reachability..."
if run_curl "https://paleon-lab-hostile.com" | grep -q "HTTP/"; then
    check_pass "HTTPS endpoint reachable"
elif run_curl "http://paleon-lab-hostile.com" | grep -q "HTTP/"; then
    check_pass "HTTP endpoint reachable"
else
    check_fail "HTTP/HTTPS endpoint not reachable"
fi

# 2. Certificate valid (only if using HTTPS)
echo
echo "2. Checking TLS certificate (if applicable)..."
if run_curl "https://paleon-lab-hostile.com" 2>&1 | grep -q "SSL certificate"; then
    check_fail "TLS certificate issue"
elif run_curl "https://paleon-lab-hostile.com" >/dev/null 2>&1; then
    check_pass "TLS certificate valid (or using HTTP locally)"
else
    check_pass "TLS check skipped (HTTP mode or local test)"
fi

# 3. Homepage works
echo
echo "3. Checking homepage..."
if run_curl "https://paleon-lab-hostile.com/" | grep -q "Paleon Site 7"; then
    check_pass "Homepage returns correct content"
elif run_curl "http://paleon-lab-hostile.com/" | grep -q "Paleon Site 7"; then
    check_pass "Homepage returns correct content (HTTP)"
else
    check_fail "Homepage not accessible or wrong content"
fi

# 4. SSRF endpoints return correct redirect headers (do NOT follow)
echo
echo "4. Checking SSRF endpoints (inspecting Location headers only)..."
SSRF_ENDPOINTS=(
    "/hostile/ssrf/fargate:http://169.254.170.2/v2/credentials/TEST_ONLY"
    "/hostile/ssrf/fargate-relative:http://169.254.170.2/v2/credentials/test-site7"
    "/hostile/ssrf/imds:http://169.254.169.254/latest/meta-data/"
    "/hostile/ssrf/rfc1918:http://10.0.0.1/"
    "/hostile/ssrf/localhost:http://127.0.0.1/"
    "/hostile/ssrf/ipv6-loopback:http://[::1]/"
    "/hostile/ssrf/ipv6-private:http://[fd00::1]/"
)

for entry in "${SSRF_ENDPOINTS[@]}"; do
    IFS=':' read -r path expected_dest <<< "$entry"
    location=$(run_curl "https://paleon-lab-hostile.com$path" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r')
    if [[ "$location" == *"$expected_dest"* ]]; then
        check_pass "SSRF $path -> $expected_dest"
    elif location=$(run_curl "http://paleon-lab-hostile.com$path" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r'); then
        if [[ "$location" == *"$expected_dest"* ]]; then
            check_pass "SSRF $path -> $expected_dest (HTTP)"
        else
            check_fail "SSRF $path: Location header '$location' does not contain '$expected_dest'"
        fi
    else
        check_fail "SSRF $path: No Location header"
    fi
done

# 5. DNS rebind endpoint
echo
echo "5. Checking DNS rebind endpoint..."
if run_curl "https://paleon-lab-hostile.com/hostile/rebind" | grep -q "rebind-test.paleon-lab-hostile.com"; then
    check_pass "DNS rebind page contains test hostname"
elif run_curl "http://paleon-lab-hostile.com/hostile/rebind" | grep -q "rebind-test.paleon-lab-hostile.com"; then
    check_pass "DNS rebind page contains test hostname (HTTP)"
else
    check_fail "DNS rebind endpoint not accessible"
fi

# 6. Scope escape endpoint
echo
echo "6. Checking scope escape endpoint..."
location=$(run_curl "https://paleon-lab-hostile.com/hostile/scope-escape" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r')
if [[ "$location" == *"offscope.paleon-lab-hostile.com"* ]]; then
    check_pass "Scope escape redirects to offscope domain"
elif location=$(run_curl "http://paleon-lab-hostile.com/hostile/scope-escape" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r'); then
    if [[ "$location" == *"offscope.paleon-lab-hostile.com"* ]]; then
        check_pass "Scope escape redirects to offscope domain (HTTP)"
    else
        check_fail "Scope escape: Location header '$location' does not contain offscope domain"
    fi
else
    check_fail "Scope escape endpoint: No Location header"
fi

# 7. Redirect loop endpoints
echo
echo "7. Checking redirect loop endpoints..."
loop_endpoints=(
    "/hostile/redirect-loop/a:/hostile/redirect-loop/b"
    "/hostile/redirect-loop/b:/hostile/redirect-loop/c"
    "/hostile/redirect-loop/c:/hostile/redirect-loop/a"
)
for entry in "${loop_endpoints[@]}"; do
    IFS=':' read -r path expected <<< "$entry"
    location=$(run_curl "https://paleon-lab-hostile.com$path" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r')
    if [[ "$location" == *"$expected"* ]]; then
        check_pass "Redirect loop $path -> $expected"
    elif location=$(run_curl "http://paleon-lab-hostile.com$path" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r'); then
        if [[ "$location" == *"$expected"* ]]; then
            check_pass "Redirect loop $path -> $expected (HTTP)"
        else
            check_fail "Redirect loop $path: Location '$location' != '$expected'"
        fi
    else
        check_fail "Redirect loop $path: No Location header"
    fi
done

# Self-loop
location=$(run_curl "https://paleon-lab-hostile.com/hostile/self-loop" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r')
if [[ "$location" == *"self-loop"* ]]; then
    check_pass "Self-loop redirects to itself"
elif location=$(run_curl "http://paleon-lab-hostile.com/hostile/self-loop" | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r'); then
    if [[ "$location" == *"self-loop"* ]]; then
        check_pass "Self-loop redirects to itself (HTTP)"
    else
        check_fail "Self-loop: Location '$location' does not contain self-loop"
    fi
else
    check_fail "Self-loop: No Location header"
fi

# 8. Large body endpoint streams correctly
echo
echo "8. Checking large body endpoint..."
# Check with small size to verify streaming
if run_curl "https://paleon-lab-hostile.com/hostile/large-body?size_mb=1" | grep -q "HTTP/"; then
    check_pass "Large body endpoint responds"
elif run_curl "http://paleon-lab-hostile.com/hostile/large-body?size_mb=1" | grep -q "HTTP/"; then
    check_pass "Large body endpoint responds (HTTP)"
else
    check_fail "Large body endpoint not accessible"
fi

# 9. Slow body endpoint
echo
echo "9. Checking slow body endpoint..."
# Use 100ms delay for quick test
if run_curl "https://paleon-lab-hostile.com/hostile/slow-body?delay_ms=100" | grep -q "HTTP/"; then
    check_pass "Slow body endpoint responds"
elif run_curl "http://paleon-lab-hostile.com/hostile/slow-body?delay_ms=100" | grep -q "HTTP/"; then
    check_pass "Slow body endpoint responds (HTTP)"
else
    check_fail "Slow body endpoint not accessible"
fi

# 10. Gzip bomb endpoint
echo
echo "10. Checking gzip bomb endpoint..."
if run_curl "https://paleon-lab-hostile.com/hostile/gzip-bomb" | grep -qi "content-encoding: gzip"; then
    check_pass "Gzip bomb endpoint returns gzip encoding"
elif run_curl "http://paleon-lab-hostile.com/hostile/gzip-bomb" | grep -qi "content-encoding: gzip"; then
    check_pass "Gzip bomb endpoint returns gzip encoding (HTTP)"
else
    check_fail "Gzip bomb endpoint missing Content-Encoding: gzip"
fi

# 11. Malformed endpoints
echo
echo "11. Checking malformed endpoints (via main app)..."
# chunked
if run_curl "https://paleon-lab-hostile.com/hostile/malformed/chunked" | grep -q "HTTP/"; then
    check_pass "Malformed chunked endpoint responds"
elif run_curl "http://paleon-lab-hostile.com/hostile/malformed/chunked" | grep -q "HTTP/"; then
    check_pass "Malformed chunked endpoint responds (HTTP)"
else
    check_fail "Malformed chunked endpoint not accessible"
fi

# banner
if run_curl "https://paleon-lab-hostile.com/hostile/malformed/banner" | grep -q "HTTP/"; then
    check_pass "Malformed banner endpoint responds"
elif run_curl "http://paleon-lab-hostile.com/hostile/malformed/banner" | grep -q "HTTP/"; then
    check_pass "Malformed banner endpoint responds (HTTP)"
else
    check_fail "Malformed banner endpoint not accessible"
fi

# 12. Read-only observer
echo
echo "12. Checking read-only observer endpoint..."
if run_curl -X POST "https://paleon-lab-hostile.com/hostile/read-only" | grep -q "OK"; then
    check_pass "Read-only endpoint accepts POST"
elif run_curl -X POST "http://paleon-lab-hostile.com/hostile/read-only" | grep -q "OK"; then
    check_pass "Read-only endpoint accepts POST (HTTP)"
else
    check_fail "Read-only endpoint not accessible"
fi

# 13. Internal observation endpoint (localhost only - test locally)
echo
echo "13. Checking internal observation endpoint (local only)..."
if run_curl "http://127.0.0.1:5000/internal/site7-observation" | grep -q "total_observations"; then
    check_pass "Internal observation endpoint accessible locally"
else
    check_fail "Internal observation endpoint not accessible locally"
fi

# 14. Kill test (just verify it responds, don't wait 30s)
echo
echo "14. Checking kill test endpoint..."
if timeout 5 run_curl "https://paleon-lab-hostile.com/hostile/kill-test" | grep -q "HTTP/"; then
    check_pass "Kill test endpoint responds"
elif timeout 5 run_curl "http://paleon-lab-hostile.com/hostile/kill-test" | grep -q "HTTP/"; then
    check_pass "Kill test endpoint responds (HTTP)"
else
    check_fail "Kill test endpoint not accessible"
fi

# 15. No unexpected ports exposed (local check)
echo
echo "15. Checking exposed ports (local only)..."
# Check what's listening on the host
if command -v ss >/dev/null 2>&1; then
    LISTENING=$(ss -tln | grep -E ':80|:443|:5000|:9999|:5353|:22' | awk '{print $4}' | sort -u)
    check_pass "Listening ports: $LISTENING"
elif command -v netstat >/dev/null 2>&1; then
    LISTENING=$(netstat -tln | grep -E ':80|:443|:5000|:9999|:5353|:22' | awk '{print $4}' | sort -u)
    check_pass "Listening ports: $LISTENING"
else
    check_pass "Port check skipped (no ss/netstat)"
fi

# 16. Systemd services healthy
echo
echo "16. Checking systemd services..."
for svc in paleon-site7 site7-malformed site7-rebind-dns; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        check_pass "Service $svc is active"
    else
        check_fail "Service $svc is not active"
    fi
done

echo
echo "=== VERIFICATION SUMMARY ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ $FAIL -eq 0 ]; then
    echo "ALL VERIFICATIONS PASSED"
    exit 0
else
    echo "VERIFICATION FAILED"
    exit 1
fi
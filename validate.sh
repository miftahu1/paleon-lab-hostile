#!/usr/bin/env bash
# PALEON SITE 7 — STATIC VALIDATION of the final architecture
# Does not require a deployed host, AWS credentials, or Docker.
set -euo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

check_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

echo "=== PALEON SITE 7 STATIC VALIDATION ==="
echo

# --- required files ---
for f in expected.yaml README.md ARCHITECTURE.md DEPLOYMENT.md CHANGES.md \
         requirements.txt reset.sh validate.sh verify.sh test_all_endpoints.py \
         app/app.py app/malformed_server.py app/rebind_dns_server.py \
         terraform/main.tf terraform/variables.tf terraform/outputs.tf \
         terraform/user_data.sh.tftpl terraform/versions.tf terraform/backend.tf \
         docs/README.md docs/ARCHITECTURE.md docs/DEPLOYMENT.md docs/API.md \
         docs/OPERATIONS.md docs/dns-rebinding.md docs/isolation.md \
         docs/malformed-protocols.md docs/port-map.md docs/resource-exhaustion.md \
         docs/test-matrix.md docs/threat-model.md .gitignore; do
    if [ -f "$f" ]; then
        check_pass "exists: $f"
    else
        check_fail "missing: $f"
    fi
done

if [ -f expected.yaml ]; then
    if python3 -c "import yaml; yaml.safe_load(open('expected.yaml'))" 2>/dev/null; then
        check_pass "expected.yaml is valid YAML"
    else
        check_fail "expected.yaml is invalid YAML"
    fi
fi

# --- expected.yaml hosts ---
if python3 - << 'PY'
import sys, yaml
data = yaml.safe_load(open("expected.yaml"))
auth = set(data.get("authorized_hosts") or [])
need = {
    "paleon-lab-hostile.com",
    "malformed-http.paleon-lab-hostile.com",
    "malformed-tls.paleon-lab-hostile.com",
    "rebind-test.paleon-lab-hostile.com",
}
if data.get("offscope_host") != "offscope.paleon-lab-hostile.com":
    sys.exit(1)
if auth != need:
    sys.exit(1)
if "offscope.paleon-lab-hostile.com" in auth:
    sys.exit(1)
sys.exit(0)
PY
then
    check_pass "expected.yaml authorized_hosts and offscope_host"
else
    check_fail "expected.yaml authorized_hosts/offscope mismatch"
fi

# --- tracked generated artifacts ---
if git ls-files | grep -E '(__pycache__|\.pyc$)' >/dev/null; then
    check_fail "tracked __pycache__ or .pyc files"
else
    check_pass "no tracked __pycache__/.pyc"
fi

# --- stale architecture strings (exclude this script) ---
scan_fail_if_found() {
    local pattern="$1"
    local msg="$2"
    local hits
    hits="$(grep -RInE "$pattern" \
        --exclude-dir=.git \
        --exclude-dir=.terraform \
        --exclude='validate.sh' \
        --exclude='*.pyc' \
        . 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        check_fail "$msg"
        echo "$hits" | head -n 20
    else
        check_pass "$msg (absent)"
    fi
}

scan_fail_if_found '\b5001\b' "stale port 5001"
scan_fail_if_found '\b5002\b' "stale port 5002"
scan_fail_if_found '\b5353\b' "stale port 5353"
scan_fail_if_found '\b8053\b' "stale port 8053"
scan_fail_if_found 'site7\.paleon-lab-hostile\.com' "stale hostname site7.paleon-lab-hostile.com"
scan_fail_if_found 'paleon-site7\.git' "stale repo URL paleon-site7.git"
scan_fail_if_found 'Amazon Linux' "Amazon Linux reference"
scan_fail_if_found '\bec2-user\b' "ec2-user reference"
scan_fail_if_found 'docker[ -]compose' "Docker Compose reference"
scan_fail_if_found 'C:/Users|/home/mifta' "developer absolute path"
scan_fail_if_found '93\.184\.216\.34' "third-party public-IP fallback 93.184.216.34"

# IMDS / metadata in application/DNS (redirect stimuli in Flask are allowed)
if grep -n '169.254.169.254' app/rebind_dns_server.py app/malformed_server.py >/dev/null 2>&1; then
    check_fail "IMDS address in DNS/malformed servers"
else
    check_pass "no IMDS address in DNS/malformed servers"
fi
if grep -nE '169\.254\.169\.254|http://169\.254' app/rebind_dns_server.py >/dev/null 2>&1; then
    check_fail "DNS server references link-local metadata"
else
    check_pass "DNS server does not call metadata"
fi

# Flask must not implement SSRF fetching
if grep -nE 'requests\.|urllib\.request|http\.client|socket\.connect' app/app.py app/malformed_server.py app/rebind_dns_server.py >/dev/null 2>&1; then
    check_fail "application code contains outbound client primitives"
else
    check_pass "no outbound client primitives in application/DNS/malformed servers"
fi

if grep -n "host='127.0.0.1'" app/app.py >/dev/null && grep -n 'MAIN_PORT = 5000' app/app.py >/dev/null; then
    check_pass "Flask binds 127.0.0.1:5000"
else
    check_fail "Flask bind is not 127.0.0.1:5000"
fi

if grep -n '0.0.0.0' app/app.py app/malformed_server.py >/dev/null; then
    check_fail "0.0.0.0 bind in Flask or malformed server"
else
    check_pass "Flask/malformed servers do not bind 0.0.0.0"
fi

if grep -n 'deque(maxlen=100)' app/app.py >/dev/null; then
    check_pass "ObservationStore maxlen=100"
else
    check_fail "ObservationStore maxlen missing"
fi

if grep -n 'MAX_BODY_SIZE = 20' app/app.py >/dev/null \
   && grep -n 'MAX_DELAY = 15000' app/app.py >/dev/null \
   && grep -n 'MAX_KILL_HOLD = 15' app/app.py >/dev/null \
   && grep -n 'MAX_GZIP_DECOMPRESSED = 10' app/app.py >/dev/null; then
    check_pass "resource limits 20MB / 15s / gzip 10MB"
else
    check_fail "resource limits do not match required ceilings"
fi

if grep -n 'compressobj' app/app.py >/dev/null && grep -n 'wbits=31' app/app.py >/dev/null; then
    check_pass "gzip uses zlib.compressobj(wbits=31)"
else
    check_fail "gzip implementation is not zlib.compressobj(wbits=31)"
fi

if grep -n 'proxy_pass http://127.0.0.1:5000' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'malformed-http' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'ssl_preread' terraform/user_data.sh.tftpl >/dev/null \
   && ! grep -n 'location /malformed' terraform/user_data.sh.tftpl >/dev/null; then
    check_pass "malformed paths are not Nginx HTTP locations"
else
    check_fail "malformed HTTP may be proxied as HTTP"
fi

if grep -n 'malformed-http.${var.hostname}' terraform/main.tf >/dev/null \
   && grep -n 'malformed-tls.${var.hostname}' terraform/main.tf >/dev/null \
   && grep -n 'paleon-site7-rebind-ns' terraform/main.tf >/dev/null \
   && grep -n 'paleon-site7-ns1' terraform/main.tf >/dev/null; then
    check_pass "Route53 records for malformed hosts, ns1 glue, NS delegation"
else
    check_fail "missing Route53 malformed/ns1/delegation records"
fi

if grep -n 'aws_eip_association' terraform/main.tf >/dev/null \
   && ! grep -n 'instance = aws_instance.paleon-site7.id' terraform/main.tf >/dev/null; then
    check_pass "EIP uses association (no instance= cycle)"
else
    check_fail "EIP still attached via instance= (cycle risk)"
fi

if grep -n 'http_tokens' terraform/main.tf >/dev/null && grep -n 'required' terraform/main.tf >/dev/null; then
    check_pass "IMDSv2 required on instance"
else
    check_fail "IMDSv2 not enforced"
fi

if grep -n 'iam_instance_profile' terraform/main.tf >/dev/null; then
    check_fail "IAM instance profile present"
else
    check_pass "no IAM instance profile"
fi

if grep -n 'miftahu1/paleon-lab-hostile.git' terraform/user_data.sh.tftpl >/dev/null; then
    check_pass "bootstrap clones canonical GitHub URL"
else
    check_fail "bootstrap repo URL incorrect"
fi

if grep -n 'libnginx-mod-stream' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'ngx_stream_module.so' terraform/user_data.sh.tftpl >/dev/null; then
    check_pass "bootstrap installs/verifies Nginx stream module"
else
    check_fail "stream module install/verify missing from bootstrap"
fi

if grep -n 'site7-tls' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'chown "root:$TLS_GROUP"' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'chmod 640 /etc/ssl/site7/site7.key' terraform/user_data.sh.tftpl >/dev/null; then
    check_pass "TLS key uses dedicated group mode 640"
else
    check_fail "TLS key permission model incorrect"
fi

if grep -n 'rebind-test.$DOMAIN_NAME' terraform/user_data.sh.tftpl >/dev/null \
   || grep -n 'rebind-test.${domain_name}' terraform/user_data.sh.tftpl >/dev/null; then
    check_fail "Certbot/certificate issuance depends on rebind-test hostname"
else
    check_pass "certificate issuance does not use rebind-test hostname"
fi

if grep -n 'AmbientCapabilities=CAP_NET_BIND_SERVICE' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' terraform/user_data.sh.tftpl >/dev/null; then
    check_pass "DNS privileged bind uses CAP_NET_BIND_SERVICE"
else
    check_fail "DNS capability bind missing"
fi

# Egress isolation must survive reboot (section 21): an ENABLED systemd oneshot
# ordered before networking reinstalls the owner-uid REJECT rules every boot,
# so isolation is not merely a runtime artifact that a reboot would drop.
if grep -q 'systemctl enable site7-egress-firewall.service' terraform/user_data.sh.tftpl \
   && grep -q 'Before=network-pre.target' terraform/user_data.sh.tftpl \
   && grep -qE '\-\-uid-owner site7 -d 169\.254\.0\.0/16 -j REJECT' terraform/user_data.sh.tftpl \
   && grep -qE 'ip6tables .*--uid-owner site7 .*-j REJECT' terraform/user_data.sh.tftpl; then
    check_pass "egress isolation reboot-persistent (enabled oneshot; owner-uid REJECT incl. metadata + IPv6)"
else
    check_fail "egress isolation not reboot-persistent or missing owner-uid REJECT rules"
fi

if grep -n 'ThreadPoolExecutor' app/rebind_dns_server.py >/dev/null \
   && grep -n 'tcp_semaphore' app/rebind_dns_server.py >/dev/null \
   && grep -n 'udp_semaphore' app/rebind_dns_server.py >/dev/null; then
    check_pass "DNS TCP/UDP concurrency bounded"
else
    check_fail "DNS concurrency not bounded"
fi

if grep -n 'ThreadPoolExecutor' app/malformed_server.py >/dev/null \
   && grep -n 'BoundedSemaphore' app/malformed_server.py >/dev/null; then
    check_pass "malformed server concurrency bounded"
else
    check_fail "malformed server uses unbounded threading"
fi

if grep -n 'SITE7_EIP' app/rebind_dns_server.py >/dev/null \
   && grep -n 'FATAL' app/rebind_dns_server.py >/dev/null; then
    check_pass "DNS fails closed without SITE7_EIP"
else
    check_fail "DNS missing hard-fail for absent EIP"
fi

if grep -n 'sys.argv' test_all_endpoints.py >/dev/null \
   && grep -n 'Usage: python3 test_all_endpoints.py' test_all_endpoints.py >/dev/null \
   && ! grep -n 'gethostbyname(BASE_DOMAIN)' test_all_endpoints.py >/dev/null; then
    check_pass "test_all_endpoints.py requires explicit EIP"
else
    check_fail "test_all_endpoints.py may invent EIP from DNS"
fi

# duplicate requirements / terraform trees
if [ -f app/requirements.txt ]; then
    check_fail "duplicate app/requirements.txt (canonical is ./requirements.txt)"
else
    check_pass "single requirements.txt at repo root"
fi
tf_count="$(find . -name 'main.tf' -not -path './.git/*' | wc -l | tr -d ' ')"
if [ "$tf_count" = "1" ]; then
    check_pass "single Terraform main.tf"
else
    check_fail "duplicate Terraform trees ($tf_count main.tf files)"
fi

# || true audit: only allow stopping services that may not exist yet, and iptables -C existence checks
while IFS= read -r line; do
    file="${line%%:*}"
    rest="${line#*:}"
    if echo "$rest" | grep -qE 'systemctl stop|iptables -C|ip6tables -C'; then
        continue
    fi
    check_fail "hidden || true in $file :: $rest"
done < <(grep -Rn '|| true' --exclude-dir=.git --exclude-dir=.terraform --exclude='validate.sh' . || true)

if grep -n 'BOOTSTRAP COMPLETE' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'HARDENED HEALTH GATE' terraform/user_data.sh.tftpl >/dev/null; then
    check_pass "bootstrap has health gate before complete"
else
    check_fail "bootstrap health gate missing"
fi

# Flask endpoints
if [ -f app/app.py ]; then
    for ep in \
        "/hostile/ssrf/fargate" \
        "/hostile/ssrf/fargate-relative" \
        "/hostile/ssrf/imds" \
        "/hostile/ssrf/rfc1918" \
        "/hostile/ssrf/localhost" \
        "/hostile/ssrf/ipv6-loopback" \
        "/hostile/ssrf/ipv6-private" \
        "/hostile/scope-escape" \
        "/hostile/redirect-loop" \
        "/hostile/redirect-loop/a" \
        "/hostile/large-body" \
        "/hostile/slow-body" \
        "/hostile/gzip-bomb" \
        "/hostile/rebind" \
        "/hostile/read-only" \
        "/hostile/kill-test" \
        "/internal/site7-observation" \
        "/health"; do
        if grep -q "$ep" app/app.py; then
            check_pass "endpoint $ep"
        else
            check_fail "endpoint $ep missing"
        fi
    done
fi

for ep in "/malformed/chunked" "/malformed/banner"; do
    if grep -q "$ep" app/malformed_server.py; then
        check_pass "malformed endpoint $ep"
    else
        check_fail "malformed endpoint $ep missing"
    fi
done

if [ -f expected.yaml ]; then
    RESILIENCE_IDS=$(python3 -c "
import yaml
data = yaml.safe_load(open('expected.yaml'))
for test in data.get('resilience_tests', []):
    print(test['id'])
" | tr -d '\r')
    for rid in $RESILIENCE_IDS; do
        if grep -q "$rid" app/app.py || grep -q "$rid" app/malformed_server.py || grep -q "$rid" app/rebind_dns_server.py; then
            check_pass "resilience id $rid"
        else
            check_fail "resilience id $rid missing from code"
        fi
    done
fi

for sh in reset.sh validate.sh verify.sh; do
    if bash -n "$sh"; then
        check_pass "$sh bash -n"
    else
        check_fail "$sh bash -n failed"
    fi
    if head -5 "$sh" | grep -q 'set -euo pipefail'; then
        check_pass "$sh set -euo pipefail"
    else
        check_fail "$sh missing set -euo pipefail"
    fi
done

# secrets (-e so the leading dashes in the PEM header are not parsed as flags)
if grep -RInE --exclude-dir=.git --exclude='validate.sh' -e '-----BEGIN.*PRIVATE KEY-----|AKIA[0-9A-Z]{16}' . >/dev/null; then
    check_fail "private key or AWS access key material in tree"
else
    check_pass "no private keys / AWS access keys in tree"
fi

echo
echo "=== VALIDATION SUMMARY ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
fi
echo "VALIDATION FAILED"
exit 1

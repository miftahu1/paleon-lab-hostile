#!/usr/bin/env bash
# PALEON SITE 7 — STATIC VALIDATION of the dedicated subdomain architecture
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
    "imds.paleon-lab-hostile.com",
    "fargate.paleon-lab-hostile.com",
    "rfc1918.paleon-lab-hostile.com",
    "loopback.paleon-lab-hostile.com",
    "ipv6.paleon-lab-hostile.com",
    "redirect-loop.paleon-lab-hostile.com",
    "self-loop.paleon-lab-hostile.com",
    "large-body.paleon-lab-hostile.com",
    "slow-body.paleon-lab-hostile.com",
    "gzip-body.paleon-lab-hostile.com",
    "observer.paleon-lab-hostile.com",
    "kill-test.paleon-lab-hostile.com",
    "ftp-redirect.paleon-lab-hostile.com",
    "slow-drip.paleon-lab-hostile.com",
    "slow-tls.paleon-lab-hostile.com",
    "malformed-http.paleon-lab-hostile.com",
    "malformed-tls.paleon-lab-hostile.com",
    "offscope-redirect.paleon-lab-hostile.com",
    "rebind-test.paleon-lab-hostile.com",
}
if data.get("offscope_domain_variable") != "OFFSCOPE_DOMAIN":
    sys.exit(1)
if auth != need:
    sys.exit(1)
if "offscope" + ".paleon-lab-hostile.com" in auth:
    sys.exit(1)
sys.exit(0)
PY
then
    check_pass "expected.yaml authorized_hosts and offscope configuration"
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
scan_fail_if_found 'site7\.paleon''-lab-hostile\.com' "stale Site 7 hostname"
scan_fail_if_found 'paleon-site7\.git' "stale repo URL paleon-site7.git"
scan_fail_if_found 'Amazon Linux' "Amazon Linux reference"
scan_fail_if_found '\bec2-user\b' "ec2-user reference"
scan_fail_if_found 'docker[ -]compose' "Docker Compose reference"
scan_fail_if_found 'C:/Users|/home/mifta' "developer absolute path"
scan_fail_if_found '93\.184\.216\.34' "third-party public-IP fallback 93.184.216.34"
scan_fail_if_found 'offscope\.paleon''-lab-hostile\.com' "stale in-scope off-scope hostname"
scan_fail_if_found '/host''ile/' "stale path-based hostile endpoint architecture"
scan_fail_if_found 'offscope_''hostname' "stale off-scope variable"
scan_fail_if_found 'us-east''-1' "stale AWS region"

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

if grep -nF '0.0.0.0' app/app.py app/malformed_server.py >/dev/null; then
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

if grep -n 'proxy_buffering off;' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'proxy_read_timeout 660s;' terraform/user_data.sh.tftpl >/dev/null \
   && grep -n 'proxy_timeout 660s;' terraform/user_data.sh.tftpl >/dev/null; then
    check_pass "Nginx preserves streams with finite 660s timeouts"
else
    check_fail "Nginx streaming or finite timeout configuration missing"
fi

if grep -nF 'location = /internal/site7-observation { return 404; }' terraform/user_data.sh.tftpl >/dev/null \
   && grep -nF 'internal/site7-observation' test_all_endpoints.py >/dev/null; then
    check_pass "public observation endpoint blocked and regression-tested"
else
    check_fail "public observation endpoint isolation regression missing"
fi

if grep -n 'paleon-site7-subdomains' terraform/main.tf >/dev/null \
   && grep -n 'paleon-site7-rebind-ns' terraform/main.tf >/dev/null \
   && grep -n 'paleon-site7-ns1' terraform/main.tf >/dev/null; then
    check_pass "Route53 records for hostile subdomains, ns1 glue, NS delegation"
else
    check_fail "missing Route53 hostile subdomains/ns1/delegation records"
fi

if grep -n 'data "aws_caller_identity" "current"' terraform/main.tf >/dev/null \
   && grep -n 'expected_aws_account_id' terraform/variables.tf terraform/main.tf >/dev/null \
   && grep -n 'current_aws_account_id' terraform/outputs.tf >/dev/null; then
    check_pass "AWS caller identity output and expected account precondition"
else
    check_fail "AWS account guard/output missing"
fi

ACCOUNT_PRECONDITIONS=$(grep -c 'condition.*data.aws_caller_identity.current.account_id == var.expected_aws_account_id' terraform/main.tf || true)
if grep -A6 'variable "expected_aws_account_id"' terraform/variables.tf | grep -q '^[[:space:]]*type[[:space:]]*=[[:space:]]*string' \
   && ! grep -A6 'variable "expected_aws_account_id"' terraform/variables.tf | grep -q '^[[:space:]]*default[[:space:]]*=' \
   && [ "$ACCOUNT_PRECONDITIONS" -ge 8 ]; then
    check_pass "expected AWS account ID is mandatory and guarded on all resources"
else
    check_fail "expected AWS account ID can be omitted or a resource lacks its guard"
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

# Egress isolation must survive reboot: an ENABLED systemd oneshot ordered before
# networking installs reply-only conntrack + explicit REJECT rules for the site7 user.
if grep -q 'systemctl enable site7-egress-firewall.service' terraform/user_data.sh.tftpl \
   && grep -q 'Before=network-pre.target' terraform/user_data.sh.tftpl \
   && grep -q 'WantedBy=network-pre.target' terraform/user_data.sh.tftpl \
   && ! grep -q 'Wants=network-pre.target' terraform/user_data.sh.tftpl \
   && grep -qE -- '\-\-uid-owner site7 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' terraform/user_data.sh.tftpl \
   && grep -qE -- '\-\-uid-owner site7 -d 169\.254\.0\.0/16 -j REJECT' terraform/user_data.sh.tftpl \
   && grep -qE -- '\-\-uid-owner site7 -d 127\.0\.0\.0/8(\s+)?-j REJECT' terraform/user_data.sh.tftpl \
   && grep -qE -- '\-\-uid-owner site7 -m conntrack --ctstate NEW -j REJECT' terraform/user_data.sh.tftpl \
   && grep -qE 'ip6tables .*--uid-owner site7 .*-j REJECT' terraform/user_data.sh.tftpl; then
    check_pass "egress isolation reboot-persistent (reply-only conntrack; explicit metadata, loopback & IPv6 REJECT)"
else
    check_fail "egress isolation missing required reply-only conntrack or destination rules"
fi

if grep -q 'Requires=site7-egress-firewall.service' terraform/user_data.sh.tftpl \
   && grep -q 'After=site7-egress-firewall.service' terraform/user_data.sh.tftpl \
   && grep -q 'systemctl start site7-egress-firewall.service' terraform/user_data.sh.tftpl; then
    check_pass "firewall starts before and is required by every Site 7 unit"
else
    check_fail "firewall startup dependency missing"
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
    if echo "$rest" | grep -qE 'systemctl stop|iptables -C|ip6tables -C|iptables -N|ip6tables -N'; then
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

# Dedicated Subdomains in Flask
if [ -f app/app.py ]; then
    for sub in \
        "imds" \
        "fargate" \
        "rfc1918" \
        "loopback" \
        "ipv6" \
        "redirect-loop" \
        "self-loop" \
        "large-body" \
        "slow-body" \
        "gzip-body" \
        "observer" \
        "kill-test" \
        "ftp-redirect" \
        "slow-drip" \
        "offscope-redirect"; do
        if grep -q "\"$sub\":" app/app.py; then
            check_pass "subdomain handler $sub"
        else
            check_fail "subdomain handler $sub missing"
        fi
    done
    if grep -q "def health" app/app.py && grep -q "def internal_observation" app/app.py; then
        check_pass "health and internal_observation endpoints"
    else
        check_fail "health or internal_observation endpoint missing"
    fi
fi

for ep in "/chunked" "/banner"; do
    if grep -q "$ep" app/malformed_server.py; then
        check_pass "malformed endpoint $ep"
    else
        check_fail "malformed endpoint $ep missing"
    fi
done

if grep -q 'PORT_SLOW_TLS = 9997' app/malformed_server.py; then
    check_pass "slow TLS on port 9997"
else
    check_fail "slow TLS missing on port 9997"
fi

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

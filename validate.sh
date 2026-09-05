#!/usr/bin/env bash
# PALEON SITE 7 — STATIC VALIDATION
# Checks all required files and configurations exist and are valid
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

echo "=== PALEON SITE 7 STATIC VALIDATION ==="
echo

# 1. expected.yaml exists and is valid YAML
if [ -f "expected.yaml" ]; then
    if python3 -c "import yaml; yaml.safe_load(open('expected.yaml'))" 2>/dev/null; then
        check_pass "expected.yaml exists and is valid YAML"
    else
        check_fail "expected.yaml exists but is invalid YAML"
    fi
else
    check_fail "expected.yaml missing"
fi

# 2. README.md exists
if [ -f "README.md" ]; then
    check_pass "README.md exists"
else
    check_fail "README.md missing"
fi

# 3. ARCHITECTURE.md exists
if [ -f "ARCHITECTURE.md" ]; then
    check_pass "ARCHITECTURE.md exists"
else
    check_fail "ARCHITECTURE.md missing"
fi

# 4. DEPLOYMENT.md exists
if [ -f "DEPLOYMENT.md" ]; then
    check_pass "DEPLOYMENT.md exists"
else
    check_fail "DEPLOYMENT.md missing"
fi

# 5. docs/ directory exists with required files
if [ -d "docs" ]; then
    check_pass "docs/ directory exists"
    for req in "README.md" "ARCHITECTURE.md" "DEPLOYMENT.md" "API.md" "OPERATIONS.md"; do
        if [ -f "docs/$req" ]; then
            check_pass "docs/$req exists"
        else
            check_fail "docs/$req missing"
        fi
    done
else
    check_fail "docs/ directory missing"
fi

# 6. No private keys, .env, terraform state, real credentials, hardcoded AWS keys
SENSITIVE_PATTERNS=(
    "-----BEGIN.*PRIVATE KEY-----"
    "AKIA[0-9A-Z]{16}"
    "aws_access_key_id\s*="
    "aws_secret_access_key\s*="
    "password\s*=\s*['\"][^'\"]{8,}"
    "secret\s*=\s*['\"][^'\"]{8,}"
)

for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    if grep -rE "$pattern" --exclude-dir=.git --exclude="*.pyc" . 2>/dev/null | grep -v "validate.sh" | grep -v "expected.yaml" >/dev/null; then
        check_fail "Sensitive pattern found: $pattern"
    else
        check_pass "No sensitive pattern: $pattern"
    fi
done

# Check for actual .env files (not just patterns mentioning them)
if find . -name ".env" -not -path "./.git/*" 2>/dev/null | grep -q .; then
    check_fail ".env file found in repository"
else
    check_pass "No .env file in repository"
fi

# Check for actual terraform state files
if find . -name "terraform.tfstate" -not -path "./.git/*" 2>/dev/null | grep -q .; then
    check_fail "terraform.tfstate found in repository"
else
    check_pass "No terraform.tfstate in repository"
fi

# 7. All Python files exist
PYTHON_FILES=(
    "app/app.py"
    "app/malformed_server.py"
    "app/rebind_dns_server.py"
    "requirements.txt"
)

for py in "${PYTHON_FILES[@]}"; do
    if [ -f "$py" ]; then
        check_pass "$py exists"
    else
        check_fail "$py missing"
    fi
done

# 8. requirements.txt exists and valid
if [ -f "requirements.txt" ]; then
    check_pass "requirements.txt exists"
    # Validate requirements.txt format (basic syntax check, not dependency resolution)
    # pip check requires installed packages; we only validate format here
    if python3 -c "
import sys
with open('requirements.txt') as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#'):
            # Basic validation: should look like package[extra]==version or package>=version etc
            if '==' in line or '>=' in line or '<=' in line or '>' in line or '<' in line or '~=' in line:
                pkg = line.split('==')[0].split('>=')[0].split('<=')[0].split('>')[0].split('<')[0].split('~=')[0].strip()
                if not pkg.replace('-', '').replace('_', '').replace('[', '').replace(']', '').isalnum():
                    print(f'Invalid package name: {pkg}', file=sys.stderr)
                    sys.exit(1)
            else:
                # Just a package name
                pkg = line.strip()
                if not pkg.replace('-', '').replace('_', '').isalnum():
                    print(f'Invalid package name: {pkg}', file=sys.stderr)
                    sys.exit(1)
" 2>/dev/null; then
        check_pass "requirements.txt has valid format"
    else
        check_fail "requirements.txt has invalid format"
    fi
else
    check_fail "requirements.txt missing"
fi

# 9. Terraform files exist
TF_FILES=(
    "terraform/main.tf"
    "terraform/variables.tf"
    "terraform/outputs.tf"
    "terraform/user_data.sh.tftpl"
    "terraform/versions.tf"
    "terraform/backend.tf"
)

for tf in "${TF_FILES[@]}"; do
    if [ -f "$tf" ]; then
        check_pass "$tf exists"
    else
        check_fail "$tf missing"
    fi
done

# 10. Shell scripts exist
SH_SCRIPTS=(
    "reset.sh"
    "validate.sh"
    "verify.sh"
    "user_data.sh"
)

for sh in "${SH_SCRIPTS[@]}"; do
    if [ -f "$sh" ]; then
        check_pass "$sh exists"
    else
        check_fail "$sh missing"
    fi
done

# 11. All required endpoints appear in Flask app source
if [ -f "app/app.py" ]; then
    REQUIRED_ENDPOINTS=(
        "/hostile/ssrf/fargate"
        "/hostile/ssrf/fargate-relative"
        "/hostile/ssrf/imds"
        "/hostile/ssrf/rfc1918"
        "/hostile/ssrf/localhost"
        "/hostile/ssrf/ipv6-loopback"
        "/hostile/ssrf/ipv6-private"
        "/hostile/scope-escape"
        "/hostile/redirect-loop/a"
        "/hostile/redirect-loop/b"
        "/hostile/redirect-loop/c"
        "/hostile/self-loop"
        "/hostile/large-body"
        "/hostile/slow-body"
        "/hostile/gzip-bomb"
        "/hostile/malformed/chunked"
        "/hostile/malformed/tls"
        "/hostile/malformed/banner"
        "/hostile/rebind"
        "/hostile/read-only"
        "/hostile/kill-test"
        "/internal/site7-observation"
    )

    for ep in "${REQUIRED_ENDPOINTS[@]}"; do
        if grep -q "$ep" app/app.py; then
            check_pass "Endpoint $ep found in app/app.py"
        else
            check_fail "Endpoint $ep missing from app/app.py"
        fi
    done
else
    check_fail "app/app.py missing, cannot check endpoints"
fi

# 12. All resilience IDs from expected.yaml appear in app code
if [ -f "expected.yaml" ] && [ -f "app/app.py" ]; then
    RESILIENCE_IDS=$(python3 -c "
import yaml
data = yaml.safe_load(open('expected.yaml'))
for test in data.get('resilience_tests', []):
    print(test['id'])
" 2>/dev/null | tr -d '\r')
    for rid in $RESILIENCE_IDS; do
        if grep -q "$rid" app/app.py; then
            check_pass "Resilience ID $rid found in app/app.py"
        else
            check_fail "Resilience ID $rid missing from app/app.py"
        fi
    done
fi

# 13. Shell scripts pass bash -n
for sh in "${SH_SCRIPTS[@]}"; do
    if [ -f "$sh" ]; then
        if bash -n "$sh" 2>/dev/null; then
            check_pass "$sh passes bash -n syntax check"
        else
            check_fail "$sh fails bash -n syntax check"
        fi
    fi
done

# 14. No stale resource references in terraform
if [ -f "main.tf" ]; then
    if grep -q "paleon-site[0-6]" main.tf 2>/dev/null; then
        check_fail "Stale site references found in main.tf"
    else
        check_pass "No stale site references in main.tf"
    fi
fi

# 15. Correct pass/fail polarity - check for unsafe patterns
UNSAFE_PATTERNS=(
    'PASS\+\+'
    'FAIL\+\+'
    '((PASS\+\+))'
    '((FAIL\+\+))'
)

for pattern in "${UNSAFE_PATTERNS[@]}"; do
    if grep -rE "$pattern" --include="*.sh" . 2>/dev/null; then
        check_fail "Unsafe increment pattern found: $pattern"
    else
        check_pass "No unsafe increment pattern: $pattern"
    fi
done

# Check for correct pattern usage
if grep -rE 'PASS=\$\(\(PASS \+ 1\)\)' --include="*.sh" . 2>/dev/null >/dev/null; then
    check_pass "Correct PASS increment pattern used"
else
    check_fail "Correct PASS increment pattern not found"
fi

if grep -rE 'FAIL=\$\(\(FAIL \+ 1\)\)' --include="*.sh" . 2>/dev/null >/dev/null; then
    check_pass "Correct FAIL increment pattern used"
else
    check_fail "Correct FAIL increment pattern not found"
fi

# 16. set -euo pipefail in all shell scripts
for sh in "${SH_SCRIPTS[@]}"; do
    if [ -f "$sh" ]; then
        if head -5 "$sh" | grep -q "set -euo pipefail"; then
            check_pass "$sh has set -euo pipefail"
        else
            check_fail "$sh missing set -euo pipefail"
        fi
    fi
done

# 17. Shebang in all shell scripts
for sh in "${SH_SCRIPTS[@]}"; do
    if [ -f "$sh" ]; then
        if head -1 "$sh" | grep -q "^#!/usr/bin/env bash"; then
            check_pass "$sh has correct shebang"
        else
            check_fail "$sh missing correct shebang"
        fi
    fi
done

echo
echo "=== VALIDATION SUMMARY ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ $FAIL -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "VALIDATION FAILED"
    exit 1
fi
#!/usr/bin/env bash
# PALEON SITE 7 — HOSTILE TEST TARGET — RESET SCRIPT
# Restores DNS rebinding state and restarts services; in-memory observations are
# discarded on restart. Idempotent: safe to run twice in a row.
set -euo pipefail

echo "=== PALEON SITE 7 RESET ==="

systemctl stop paleon-site7.service 2>/dev/null || true
systemctl stop site7-malformed-server.service 2>/dev/null || true
systemctl stop site7-rebind-dns.service 2>/dev/null || true

# Endpoint observations are stored in-memory (app.py ObservationStore, a bounded
# deque). Stopping paleon-site7.service above already discarded them; there are
# no on-disk observation logs to clear.

REBIND_STATE="/var/lib/site7/rebind-state.json"
mkdir -p /var/lib/site7
echo "Resetting DNS rebinding state: $REBIND_STATE"
cat > "$REBIND_STATE" << 'EOF'
{"query_count":0,"total_a_queries":0,"state":"public","clients":{}}
EOF
chown site7:site7 "$REBIND_STATE"
chown -R site7:site7 /var/lib/site7


echo "Starting Site 7 services..."
systemctl start site7-rebind-dns.service
systemctl start site7-malformed-server.service
systemctl start paleon-site7.service
systemctl start nginx

sleep 2

echo "Verifying service health..."
HEALTH_ERRORS=0
for svc in paleon-site7 site7-malformed-server site7-rebind-dns nginx; do
    if ! systemctl is-active --quiet "$svc"; then
        echo "[FATAL] Service '$svc' failed to restart"
        HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
    fi
done

check_listen() {
    local spec="$1"
    if ! ss -tlnp | grep -q "$spec" && ! ss -ulnp | grep -q "$spec"; then
        echo "[FATAL] Listener $spec missing"
        HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
    fi
}

if ! ss -tlnp | grep -qE ':53\b'; then
    echo "[FATAL] TCP 53 not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi
if ! ss -ulnp | grep -qE ':53\b'; then
    echo "[FATAL] UDP 53 not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi
if ! ss -tlnp | grep -qE ':80\b'; then
    echo "[FATAL] TCP 80 not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi
if ! ss -tlnp | grep -qE ':443\b'; then
    echo "[FATAL] TCP 443 not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi
if ! ss -tlnp | grep -q '127.0.0.1:5000'; then
    echo "[FATAL] TCP 5000 localhost not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi
if ! ss -tlnp | grep -q '127.0.0.1:8443'; then
    echo "[FATAL] TCP 8443 localhost not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi
if ! ss -tlnp | grep -q '127.0.0.1:9998'; then
    echo "[FATAL] TCP 9998 localhost not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi
if ! ss -tlnp | grep -q '127.0.0.1:9999'; then
    echo "[FATAL] TCP 9999 localhost not listening"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi

if ! curl -sf --max-time 5 http://127.0.0.1:5000/health >/dev/null; then
    echo "[FATAL] Flask health check failed"
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
fi

if [ "$HEALTH_ERRORS" -gt 0 ]; then
    echo "=== RESET FAILED ==="
    exit 1
fi

echo "=== RESET COMPLETE ==="
echo "Services restarted in known initial state."

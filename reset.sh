#!/usr/bin/env bash
# PALEON SITE 7 — HOSTILE TEST TARGET — RESET SCRIPT
# Restores site to known initial state
set -euo pipefail

# Print what we're doing
echo "=== PALEON SITE 7 RESET ==="
echo "Stopping Site 7 services..."

# Stop only Site 7 services
systemctl stop paleon-site7.service 2>/dev/null || true
systemctl stop site7-malformed.service 2>/dev/null || true
systemctl stop site7-rebind-dns.service 2>/dev/null || true

# Clear only Site 7 generated state
OBS_DIR="/var/lib/site7/observations"
if [ -d "$OBS_DIR" ]; then
    echo "Clearing observation logs: $OBS_DIR"
    rm -f "$OBS_DIR"/*.jsonl
fi

REBIND_STATE="/var/lib/site7/rebind-state.json"
if [ -f "$REBIND_STATE" ]; then
    echo "Resetting DNS rebinding state: $REBIND_STATE"
    echo '{"query_count":0,"state":"public"}' > "$REBIND_STATE"
fi

# Remove only Site 7 temporary artifacts
TEMP_DIR="/var/lib/site7/temp"
if [ -d "$TEMP_DIR" ]; then
    echo "Clearing temporary files: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
fi

# Restart services
echo "Starting Site 7 services..."
systemctl start site7-rebind-dns.service 2>/dev/null || true
systemctl start site7-malformed.service 2>/dev/null || true
systemctl start paleon-site7.service 2>/dev/null || true

echo "=== RESET COMPLETE ==="
echo "Services restarted in known initial state."
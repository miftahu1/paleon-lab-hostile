#!/usr/bin/env bash
# PALEON SITE 7 — HOSTILE TEST TARGET — BOOTSTRAP SCRIPT
# Self-contained, idempotent, retry-safe bootstrap
set -euo pipefail

echo "=== PALEON SITE 7 BOOTSTRAP START ==="
echo "Starting at $(date)"

# Variables
APP_DIR="/opt/paleon-site7"
DATA_DIR="/var/lib/site7"
LOG_FILE="/var/log/paleon-site7-bootstrap.log"

# 1. System update and prerequisites
echo "[1/14] Updating system and installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> "$LOG_FILE" 2>&1 || true
apt-get upgrade -y >> "$LOG_FILE" 2>&1 || true
apt-get install -y python3 python3-pip nginx certbot python3-certbot-nginx git >> "$LOG_FILE" 2>&1 || true

# 2. Create system user 'site7'
echo "[2/14] Creating system user 'site7'..."
if id -u site7 >/dev/null 2>&1; then
    echo "User site7 already exists, skipping creation"
else
    useradd --system --shell /bin/false --home-dir "$DATA_DIR" --create-home site7
fi

# 3. Create application directory
echo "[3/14] Creating application directory..."
mkdir -p "$APP_DIR"
mkdir -p "$DATA_DIR/observations"
mkdir -p "$DATA_DIR/rebind"
mkdir -p "$DATA_DIR/temp"

# 4. Deploy Flask app and requirements
echo "[4/14] Deploying application files..."
# In production, these would be copied or fetched; here we check if they exist
for f in app.py malformed_server.py rebind_dns.py requirements.txt; do
    if [ -f "/opt/paleon-site7/$f" ]; then
        echo "File $f already exists, skipping"
    else
        echo "Warning: $f not found at $APP_DIR/$f - should be deployed"
    fi
done

# 5. Install Python dependencies
echo "[5/14] Installing Python dependencies..."
if [ -f "$APP_DIR/requirements.txt" ]; then
    pip3 install -r "$APP_DIR/requirements.txt" --quiet >> "$LOG_FILE" 2>&1 || true
else
    echo "Warning: requirements.txt not found"
fi

# 6. Create systemd units
echo "[6/14] Creating systemd service files..."

# paleon-site7.service
cat > /etc/systemd/system/paleon-site7.service << 'SERVICEEOF'
[Unit]
Description=Paleon Site 7 - Hostile Test Target
After=network.target

[Service]
Type=simple
User=site7
Group=site7
WorkingDirectory=/opt/paleon-site7
ExecStart=/usr/bin/python3 /opt/paleon-site7/app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

# site7-malformed-server.service
cat > /etc/systemd/system/site7-malformed.service << 'SERVICEEOF'
[Unit]
Description=Site 7 Malformed Response Server
After=network.target paleon-site7.service

[Service]
Type=simple
User=site7
Group=site7
WorkingDirectory=/opt/paleon-site7
ExecStart=/usr/bin/python3 /opt/paleon-site7/malformed_server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

# site7-rebind-dns.service
cat > /etc/systemd/system/site7-rebind-dns.service << 'SERVICEEOF'
[Unit]
Description=Site 7 DNS Rebinding Simulator
After=network.target

[Service]
Type=simple
User=site7
Group=site7
WorkingDirectory=/opt/paleon-site7
ExecStart=/usr/bin/python3 /opt/paleon-site7/rebind_dns.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload

# 7. Configure Nginx
echo "[7/14] Configuring Nginx..."

# Main site configuration
cat > /etc/nginx/sites-available/site7.conf << 'NGINXEOF'
server {
    listen 80;
    server_name paleon-lab-hostile.com www.paleon-lab-hostile.com;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
    }
}
NGINXEOF

# Off-scope configuration
cat > /etc/nginx/sites-available/offscope.conf << 'NGINXEOF'
server {
    listen 80;
    server_name offscope.paleon-lab-hostile.com;

    location / {
        return 200 "Off-scope target - no content served here\n";
        add_header Content-Type text/plain;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/site7.conf /etc/nginx/sites-enabled/site7.conf
ln -sf /etc/nginx/sites-available/offscope.conf /etc/nginx/sites-enabled/offscope.conf
rm -f /etc/nginx/sites-enabled/default

# 8. Start application services
echo "[8/14] Starting application services..."
systemctl daemon-reload
systemctl stop paleon-site7.service 2>/dev/null || true
systemctl stop site7-malformed.service 2>/dev/null || true
systemctl stop site7-rebind-dns.service 2>/dev/null || true
systemctl start site7-rebind-dns.service 2>/dev/null || true
systemctl start site7-malformed.service 2>/dev/null || true
systemctl start paleon-site7.service 2>/dev/null || true

# 9. Start Nginx
echo "[9/14] Starting Nginx..."
systemctl stop nginx 2>/dev/null || true
systemctl start nginx

# Wait for services to stabilize
sleep 2

# 10. Validate local HTTP
echo "[10/14] Validating local HTTP..."
if curl -s http://localhost:5000/ 2>/dev/null | head -1 | grep -q "HTTP/"; then
    echo "[PASS] Flask app responding on port 5000"
else
    echo "[WARN] Flask app not responding on port 5000, attempting restart..."
    systemctl restart paleon-site7.service 2>/dev/null || true
    sleep 3
fi

if curl -s http://localhost/ 2>/dev/null | head -1 | grep -q "HTTP/"; then
    echo "[PASS] Nginx responding on port 80"
else
    echo "[WARN] Nginx not responding, checking configuration..."
    nginx -t 2>&1 || true
fi

# 11. Configure hostile-test services
echo "[11/14] Configuring hostile-test services..."
mkdir -p "$DATA_DIR/observations"
chmod 755 "$DATA_DIR/observations"

# Initialize rebind state if needed
if [ ! -f "$DATA_DIR/rebind-state.json" ]; then
    echo '{"query_count":0,"state":"public"}' > "$DATA_DIR/rebind-state.json"
    chown site7:site7 "$DATA_DIR/rebind-state.json"
fi

# 12. Validate all endpoints
echo "[12/14] Validating all endpoints..."
ERRORS=0

ENDPOINTS=(
    "/"
    "/hostile/ssrf/fargate"
    "/hostile/ssrf/imds"
    "/hostile/ssrf/rfc1918"
    "/hostile/ssrf/localhost"
    "/hostile/ssrf/ipv6-loopback"
    "/hostile/ssrf/ipv6-private"
    "/hostile/scope-escape"
    "/hostile/redirect-loop"
    "/hostile/large-body"
    "/hostile/slow-body"
    "/hostile/gzip-bomb"
    "/hostile/malformed/chunked"
    "/hostile/malformed/banner"
    "/hostile/read-only"
    "/hostile/kill-test"
    "/internal/site7-observation"
)

for ep in "${ENDPOINTS[@]}"; do
    if curl -s -I --max-time 5 "http://localhost:5000$ep" 2>/dev/null | head -1 | grep -q "HTTP/"; then
        echo "[PASS] Endpoint $ep responding"
    else
        echo "[FAIL] Endpoint $ep not responding"
        ERRORS=$((ERRORS + 1))
    fi
done

# 13. Enable HTTPS with certbot (if DNS is configured)
echo "[13/14] Attempting HTTPS setup..."
if host paleon-lab-hostile.com >/dev/null 2>&1; then
    echo "DNS is configured, attempting certbot..."
    certbot --nginx -d paleon-lab-hostile.com -d www.paleon-lab-hostile.com --non-interactive --agree-tos --email admin@paleon-lab-hostile.com 2>/dev/null || {
        echo "[WARN] Certbot failed - DNS may not be pointed to this server"
    }
else
    echo "[SKIP] DNS not configured for paleon-lab-hostile.com"
fi

# 14. Final status
echo "[14/14] Final status check..."
echo
echo "=== SERVICE STATUS ==="
systemctl is-active paleon-site7.service 2>/dev/null || echo "paleon-site7: inactive"
systemctl is-active site7-malformed.service 2>/dev/null || echo "site7-malformed: inactive"
systemctl is-active site7-rebind-dns.service 2>/dev/null || echo "site7-rebind-dns: inactive"
systemctl is-active nginx 2>/dev/null || echo "nginx: inactive"

echo
echo "=== LISTENING PORTS ==="
ss -tlnp 2>/dev/null | grep -E ":(5000|5001|5002|8053|80|443) " || echo "No expected ports listening"

echo
echo "=== BOOTSTRAP COMPLETE ==="
echo "Finished at $(date)"
echo "Errors: $ERRORS"

if [ $ERRORS -gt 0 ]; then
    echo "WARNING: $ERRORS endpoint(s) failed validation"
    exit 1
else
    echo "All endpoints validated successfully"
    exit 0
fi
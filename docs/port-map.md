# PALEON TEST SITE 7 — Port Mapping

## Port Map

The following table documents all network ports used by PALEON TEST SITE 7, their protocols, services, binding addresses, and exposure status.

| Port | Protocol | Service | Bind Address | Exposed Externally | Purpose |
|------|----------|---------|--------------|-------------------|---------|
| 22 | TCP | SSH | 0.0.0.0 | Admin CIDR only | Instance management |
| 53 | TCP | DNS Rebinding | 0.0.0.0 | Yes (Scanner test entry) | Authoritative DNS for rebind-test |
| 53 | UDP | DNS Rebinding | 0.0.0.0 | Yes (Scanner test entry) | Authoritative DNS for rebind-test |
| 80 | TCP | Nginx HTTP | 0.0.0.0 | Yes (redirects to 443) | HTTP→HTTPS redirect |
| 443 | TCP | Nginx HTTPS | 0.0.0.0 | Yes (Scanner entry point) | TLS termination, SNI routing |
| 5000 | TCP | Flask Application | 127.0.0.1 | **No** (Internal only) | Main application logic |
| 8443 | TCP | Nginx Internal HTTPS | 127.0.0.1 | **No** (Internal only) | Default backend for SNI routing |
| 9998 | TCP | Malformed TLS | 127.0.0.1 | **No** (Internal only) | Raw malformed TLS ServerHello |
| 9999 | TCP | Malformed HTTP | 127.0.0.1 | **No** (Internal only) | Valid TLS + malformed HTTP |

### Service Details

#### 1. Port 22 - SSH
- **Purpose**: Administrative access to the instance
- **Security**: Restricted to specific admin CIDR via security group
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: Limited to authorized admin IPs only

#### 2. Port 53 - DNS Rebinding (TCP & UDP)
- **Purpose**: Authoritative DNS server for `rebind-test.paleon-lab-hostile.com`
- **Binding**: 0.0.0.0 (all interfaces, both TCP and UDP)
- **External Exposure**: Yes - this is where scanners query for rebinding tests
- **Behavior**:
  - First query: Returns Site 7 EIP (public)
  - Subsequent queries: Returns `192.168.1.1` (private)
  - TTL: 0 (forces re-resolution)
  - Flags: AA=1 (authoritative), RA=0 (no recursion)
- **Privileges**: Runs as `site7` user with `CAP_NET_BIND_SERVICE`

#### 3. Port 80 - Nginx HTTP
- **Purpose**: HTTP listener that redirects all traffic to HTTPS
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: Yes - accepts HTTP from anywhere
- **Behavior**: Returns 301 redirect to HTTPS equivalent

#### 4. Port 443 - Nginx HTTPS (SNI Routing)
- **Purpose**: Main TLS-terminating reverse proxy with SNI routing - scanner entry point
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: Yes - this is where scanners connect
- **SNI Routing**:
  - `malformed-tls.*` → 127.0.0.1:9998 (raw malformed TLS)
  - `malformed-http.*` → 127.0.0.1:9999 (valid TLS + malformed HTTP)
  - `default` → 127.0.0.1:8443 → Flask app on 127.0.0.1:5000

#### 5. Port 5000 - Flask Application (Internal Only)
- **Purpose**: Main application logic serving all test endpoints
- **Binding**: 127.0.0.1 (loopback only)
- **External Exposure**: **No** - only accessible via Nginx proxy (127.0.0.1:8443)
- **Services**:
  - All SSRF endpoints (`/hostile/ssrf/*`)
  - All SAFE endpoints (`/hostile/*`)
  - Health check (`/health`)
  - Observation logs (`/internal/site7-observation`)
  - Index page (`/`)

#### 6. Port 8443 - Nginx Internal HTTPS Termination (Internal Only)
- **Purpose**: Internal TLS termination for default SNI backend
- **Binding**: 127.0.0.1 (loopback only)
- **External Exposure**: **No**
- **Behavior**: Terminates TLS, proxies to Flask app on 127.0.0.1:5000

#### 7. Port 9998 - Malformed TLS Server (Internal Only)
- **Purpose**: Serves raw malformed TLS ServerHello
- **Binding**: 127.0.0.1 (loopback only)
- **External Exposure**: **No** - accessed via SNI routing on 443
- **Behavior**:
  - Reads ClientHello
  - Sends garbled ServerHello with invalid version/random bytes
  - Connection cap: 10 concurrent
  - Idle timeout: 30s

#### 8. Port 9999 - Malformed HTTP Server (Internal Only)
- **Purpose**: Valid TLS handshake then raw malformed HTTP bytes
- **Binding**: 127.0.0.1 (loopback only)
- **External Exposure**: **No** - accessed via SNI routing on 443
- **Services**:
  - `/malformed/chunked` — Invalid chunked encoding (GARBAGE chunk size)
  - `/malformed/banner` — Control chars in header (`\x00\x01\x02\x03`), binary data
- **Behavior**:
  - Valid TLS handshake using site certificate
  - Sends malformed HTTP response
  - Connection cap: 10 concurrent
  - Idle timeout: 30s

### Network Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                             EXTERNAL SCANNER                            │
└───────────────────────┬─────────────────────────────────────────────────┘
                        │ HTTPS (443) / HTTP (80) / DNS (53)
                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           NGINX PROXY                                   │
│  Port 80:  HTTP → HTTPS redirect                                        │
│  Port 443: SNI Routing:                                                 │
│    malformed-tls.*     → 127.0.0.1:9998 (Raw Malformed TLS)            │
│    malformed-http.*    → 127.0.0.1:9999 (Valid TLS + Malformed HTTP)   │
│    default             → 127.0.0.1:8443 → 127.0.0.1:5000 (Flask App)   │
└───────────────────────┬─────────────────────────────────────────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
   ┌────────────┐ ┌────────────┐ ┌──────────────┐
   │  127.0.0.1 │ │  127.0.0.1 │ │  127.0.0.1   │
   │   :8443    │ │   :9998    │ │    :9999     │
   │  (Flask)   │ │ (Malformed │ │ (Malformed   │
   │            │ │   TLS)     │ │   HTTP)      │
   └────────────┘ └────────────┘ └──────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         DNS REBINDING                                   │
│                    Port 53 (TCP/UDP, 0.0.0.0)                          │
│  rebind-test.paleon-lab-hostile.com → EIP (1st) / 192.168.1.1 (2nd+)  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Important Security Notes

1. **Internal services bind to 127.0.0.1 only**: Ports 5000, 8443, 9998, 9999 are bound to loopback and are NOT accessible externally.

2. **Only ports 80, 443, 53 (TCP/UDP), and 22 (admin) are externally exposed** via security group.

3. **DNS rebinding on port 53**: This is the authoritative DNS server for `rebind-test.paleon-lab-hostile.com`, delegated via NS record to `ns1.paleon-lab-hostile.com`. Scanners connect directly to port 53 on the instance's public IP.

4. **Malformed endpoints accessed via SNI**: Scanners reach malformed TLS/HTTP by connecting to `https://malformed-tls.paleon-lab-hostile.com/` or `https://malformed-http.paleon-lab-hostile.com/` on port 443. Nginx SNI routes to the internal backends.

5. **Single-instance systemd deployment**: One Ubuntu 24.04 EC2 instance running the Python services under systemd behind Nginx — no container stack, and the service account is the dedicated `site7` user.

### Verification Commands

To verify port bindings on a running instance:

```bash
# Check what's listening on each port
ss -tlnp | grep -E ':(22|53|80|443|5000|8443|9998|9999)'
ss -ulnp | grep :53

# Expected output:
# tcp   LISTEN 0      128          0.0.0.0:22       0.0.0.0:*    users:(("sshd",pid=xxx,fd=3))
# tcp   LISTEN 0      128          0.0.0.0:53       0.0.0.0:*    users:(("python3",pid=xxx,fd=3))
# tcp   LISTEN 0      128          0.0.0.0:80       0.0.0.0:*    users:(("nginx",pid=xxx,fd=5))
# tcp   LISTEN 0      128          0.0.0.0:443      0.0.0.0:*    users:(("nginx",pid=xxx,fd=7))
# tcp   LISTEN 0      128        127.0.0.1:5000      0.0.0.0:*    users:(("python3",pid=xxx,fd=3))
# tcp   LISTEN 0      128        127.0.0.1:8443      0.0.0.0:*    users:(("nginx",pid=xxx,fd=10))
# tcp   LISTEN 0      10         127.0.0.1:9998      0.0.0.0:*    users:(("python3",pid=xxx,fd=3))
# tcp   LISTEN 0      10         127.0.0.1:9999      0.0.0.0:*    users:(("python3",pid=xxx,fd=4))
# udp   UNCONN 0      0            0.0.0.0:53       0.0.0.0:*    users:(("python3",pid=xxx,fd=4))

# Test internal endpoints
curl -s http://localhost:5000/health
curl -s http://localhost:5000/internal/site7-observation

# Test DNS rebinding
dig @localhost rebind-test.paleon-lab-hostile.com
dig @localhost rebind-test.paleon-lab-hostile.com

# Test SNI routing (from external)
curl -I https://malformed-http.paleon-lab-hostile.com/malformed/chunked
curl -I https://malformed-tls.paleon-lab-hostile.com/
```

All internal services should respond when accessed via localhost from within the instance, but should NOT be accessible directly from external networks (except ports 80, 443, 53 via nginx/DNS).
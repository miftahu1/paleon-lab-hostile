# PALEON TEST SITE 7 — Port Mapping

## Port Map

The following table documents all network ports used by PALEON TEST SITE 7, their protocols, services, binding addresses, and exposure status.

| Port | Protocol | Service | Bind Address | Exposed Externally | Purpose |
|------|----------|---------|--------------|-------------------|---------|
| 22 | TCP | SSH | 0.0.0.0 | Admin CIDR only | Instance management |
| 53 | UDP | DNS (System) | 0.0.0.0 | VPC Resolver only | Standard DNS resolution |
| 80 | TCP | Nginx HTTP | 0.0.0.0 | Yes (redirects to 443) | HTTP→HTTPS redirect |
| 443 | TCP | Nginx HTTPS | 0.0.0.0 | Yes (Scanner entry point) | TLS termination, proxy to Flask app |
| 5000 | TCP | Flask Application | 0.0.0.0 | **No** (Proxied via Nginx) | Main application logic |
| 5001 | TCP | Malformed Protocol Server | 0.0.0.0 | **No** | Additional malformed HTTP responses |
| 5002 | TCP | DNS Rebind HTTP Test | 0.0.0.0 | **No** | HTTP interface for DNS rebind test |
| 8053 | UDP | DNS Rebinding Server | 0.0.0.0 | **No** | UDP DNS server for rebinding simulation |

### Service Details

#### 1. Port 22 - SSH
- **Purpose**: Administrative access to the instance
- **Security**: Restricted to specific admin CIDR via security group
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: Limited to authorized admin IPs only

#### 2. Port 53 - System DNS
- **Purpose**: Standard DNS resolution for the instance (VPC resolver)
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: Used only by the instance for outbound DNS queries
- **Note**: This is the AWS VPC DNS resolver, not the test DNS rebind server

#### 3. Port 80 - Nginx HTTP
- **Purpose**: HTTP listener that redirects all traffic to HTTPS
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: Yes - accepts HTTP from anywhere
- **Behavior**: Returns 301 redirect to HTTPS equivalent

#### 4. Port 443 - Nginx HTTPS
- **Purpose**: Main TLS-terminating reverse proxy - scanner entry point
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: Yes - this is where scanners connect
- **Behavior**: 
  - Terminates TLS connections
  - Enforces rate limiting
  - Proxies HTTP to Flask app on localhost:5000
  - Hosts all test endpoints

#### 5. Port 5000 - Flask Application
- **Purpose**: Main application logic serving all test endpoints
- **Binding**: 0.0.0.0 (all interfaces) - *Note: while bound to all interfaces, it is not directly accessible externally due to Nginx proxying*
- **External Exposure**: **No** - only accessible via Nginx proxy (localhost:5000)
- **Services**:
  - All SSRF endpoints (`/hostile/ssrf/*`)
  - All SAFE endpoints (`/hostile/*`)
  - Health check (`/health`)
  - Observation logs (`/internal/site7-observation`)
  - Index page (`/`)

#### 6. Port 5001 - Malformed Protocol Server
- **Purpose**: Serves additional malformed HTTP responses for parser safety tests
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: **No** - isolated by design
- **Access Path**: Only reachable via SSRF-003 redirect chain (localhost path)
- **Services**:
  - `/malformed/chunked` - Invalid chunked encoding
  - `/malformed/banner` - Invalid HTTP status codes

#### 7. Port 5002 - DNS Rebinding HTTP Test
- **Purpose**: HTTP interface for testing DNS rebinding simulator
- **Binding**: 0.0.0.0 (all interfaces)
- **External Exposure**: **No**
- **Services**:
  - Returns current DNS rebind state
  - Allows manual testing of rebind logic

#### 8. Port 8053 - UDP DNS Rebinding Server
- **Purpose**: Authoritative DNS server simulating DNS rebinding attack
- **Binding**: 0.0.0.0 (all interfaces, UDP only)
- **External Exposure**: **No**
- **Zone**: `rebind-test.paleon-lab-hostile.com`
- **Behavior**:
  - First query: Returns public IP (203.0.113.42)
  - Subsequent queries: Returns private IP (10.0.0.50)
  - TTL: 0 (forces re-resolution)

### Network Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                             EXTERNAL SCANNER                            │
└───────────────────────┬─────────────────────────────────────────────────┘
                        │ HTTPS (443)
                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           NGINX PROXY                                   │
│  Port 80:  HTTP → HTTPS redirect                                       │
│  Port 443: HTTPS → HTTP(proxied to 5000)                               │
└─────────────────┬───────────────────────────────────────────────────────┘
                  │ HTTP (proxied)
                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        FLASK APPLICATION                                │
│                     Port 5000 (0.0.0.0:5000)                            │
│  • SSRF endpoints                                                       │
│  • SAFE endpoints                                                       │
│  • Health/check endpoints                                               │
└─────────┬─────────────────────┬─────────────────────┬───────────────────┘
          │                     │                     │
          ▼                     ▼                     ▼
┌─────────────┐         ┌──────────────┐        ┌────────────────┐
│ Port 5001   │         │ Port 5002    │        │ Port 8053 (UDP)│
│Malformed Svr│         │Rebind HTTP   │        │DNS Rebinding   │
│• /malformed/*│         │• State API   │        │• rebind-test...│
└─────────────┘         └──────────────┘        └────────────────┘
   (Localhost Only)      (Localhost Only)       (Localhost Only)
```

### Important Security Notes

1. **Ports 5001, 5002, and 8053 are localhost-only in practice**: While they bind to 0.0.0.0 in the container, they are designed to be accessed only through:
   - Localhost paths from the Flask app (for SSRF-003)
   - Internal container networking
   - They should NOT be exposed externally in production deployments

2. **SSRF-003 Path**: The only external path to ports 5001/5002/8053 is:
   ```
   Scanner → GET /hostile/ssrf/localhost → 302 → http://127.0.0.1:5001/* 
           or  http://127.0.0.1:5002/* 
           or  http://127.0.0.1:8053/* (UDP DNS)
   ```
   A properly behaving scanner will block this redirect to localhost.

3. **No Direct External Access**: There are no nginx proxy rules or firewall rules that allow direct external access to ports 5001, 5002, or 8053. They are only reachable via the localhost redirect path.

4. **Container Networking**: In the Docker Compose deployment (for local testing), these services may be exposed on the host network. In the AWS EC2 deployment, they bind to 0.0.0.0 but are protected by the instance's security group which only allows inbound to ports 22, 80, and 443.

### Verification Commands

To verify port bindings on a running instance:

```bash
# Check what's listening on each port
ss -tlnp | grep -E ':(22|53|80|443|5000|5001|5002|8053)'

# From inside the container/instance:
curl -s http://localhost:5000/health
curl -s http://localhost:5001/malformed/chunked | head -c 100
curl -s http://localhost:5002/
dig @localhost -p 8053 rebind-test.paleon-lab-hostile.com
```

All services should respond when accessed via localhost from within the instance, but should not be accessible directly from external networks (except ports 80/443 via nginx).
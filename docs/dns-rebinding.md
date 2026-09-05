# PALEON TEST SITE 7 — DNS Rebinding Architecture

## Overview

This document describes the DNS rebinding test implementation for Site 7. The test validates that the scanner re-validates DNS resolution on reconnect and refuses connections to private addresses after rebinding.

---

## 1. Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────────┐
│                      SCANNER (External)                              │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      DNS RESOLUTION                                 │
│                                                                      │
│  First lookup:                                                       │
│  rebind-test.paleon-lab-hostile.com  ->  93.184.216.34 (public)    │
│                                                                      │
│  Subsequent lookups (TTL=0 forces re-query):                         │
│  rebind-test.paleon-lab-hostile.com  ->  192.168.1.1 (private)     │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    DNS REBIND SERVER                                │
│                                                                      │
│  - Listens on 127.0.0.1:5353 (UDP)                                  │
│  - Authoritative for rebind-test.paleon-lab-hostile.com            │
│  - Tracks query count per session                                   │
│  - Persists state to /var/lib/site7/rebind-state.json              │
│  - Reset capability: python rebind_dns_server.py reset              │
└─────────────────────────────────────────────────────────────────────┘
```

### Test Flow

1. **Scanner resolves hostname** → Gets public IP (93.184.216.34)
2. **Scanner connects to public IP** → Reaches Site 7 Nginx
3. **Scanner follows redirect or makes new connection** → Must re-resolve DNS
4. **Second DNS query** → Gets private IP (192.168.1.1)
5. **Scanner should detect rebinding** → Refuse connection to private IP

---

## 2. Implementation Details

### DNS Server (`app/rebind_dns_server.py`)

**Protocol**: Raw UDP DNS (RFC 1035), no external dependencies

**State Management**:
- In-memory query counter
- Persisted to `/var/lib/site7/rebind-state.json`
- Survives process restart
- Reset via CLI argument: `python rebind_dns_server.py reset`

**Response Logic**:
```python
def get_answer_ip(self):
    with self.lock:
        if self.query_count == 0:
            self.query_count += 1
            self.save_state()
            return "93.184.216.34"  # Public test IP (example.com)
        else:
            self.query_count += 1
            if self.query_count > MAX_QUERIES:
                self.reset()  # Safety: wrap around
                return "93.184.216.34"
            self.save_state()
            return "192.168.1.1"  # Private IP
```

**TTL**: Always 0 — forces re-resolution on every query

**Logging**: Structured JSON logs for each query:
```json
{
  "timestamp": "2026-09-04T...",
  "level": "INFO",
  "message": "dns_query",
  "query_count": 1,
  "query_name": "rebind-test.paleon-lab-hostile.com",
  "answer_ip": "93.184.216.34",
  "client_ip": "127.0.0.1"
}
```

---

## 3. Route53 Configuration

### Production DNS Records

```hcl
# Primary domain - points to Site 7 EIP
paleon-lab-hostile.com.        300  IN  A  <EIP>

# Off-scope domain - same EIP, different hostname
offscope.paleon-lab-hostile.com.  300  IN  A  <EIP>

# Rebinding test - initially points to public test IP
rebind-test.paleon-lab-hostile.com.  60  IN  A  93.184.216.34
```

**Note**: The rebind test hostname in Route53 initially points to a public test IP (93.184.216.34). The actual rebinding behavior is implemented by the **local DNS server** on port 5353, not by Route53. Route53 provides the initial public resolution; the local server handles the rebinding sequence.

### Why This Design?

- **Deterministic**: No timing races, no third-party DNS
- **Controlled**: Lab owns all DNS infrastructure
- **Isolated**: Local DNS server on 127.0.0.1:5353
- **Resettable**: Single command restores initial state
- **Observable**: Every query logged with sequence number

---

## 4. Test Execution

### For Scanner Testing

The scanner should be configured to use the Site 7 DNS server for the rebind test hostname, OR the test should be run in an environment where `rebind-test.paleon-lab-hostile.com` resolves via the local DNS server.

**Option 1: Scanner uses Site 7 as DNS resolver**
- Configure scanner DNS to include 127.0.0.1:5353 (requires network access to Site 7 instance)

**Option 2: Hosts file / local resolver override**
- During test, override resolution for rebind-test hostname to use local DNS server

**Option 3: Direct DNS queries to test server**
- Scanner makes DNS queries directly to 127.0.0.1:5353 for rebind-test hostname

### Manual Verification

```bash
# First query - should return public IP
dig @127.0.0.1 -p 5353 rebind-test.paleon-lab-hostile.com +short
# Expected: 93.184.216.34

# Second query - should return private IP
dig @127.0.0.1 -p 5353 rebind-test.paleon-lab-hostile.com +short
# Expected: 192.168.1.1

# Third query - still private (until reset)
dig @127.0.0.1 -p 5353 rebind-test.paleon-lab-hostile.com +short
# Expected: 192.168.1.1

# Reset state
python app/rebind_dns_server.py reset

# After reset - back to public
dig @127.0.0.1 -p 5353 rebind-test.paleon-lab-hostile.com +short
# Expected: 93.184.216.34
```

---

## 5. Expected Scanner Behavior

### Pass Criteria (SAFE-007)

The scanner **must**:
1. ✅ Resolve `rebind-test.paleon-lab-hostile.com` initially
2. ✅ Connect to the resolved address (public IP)
3. ✅ On subsequent connection attempt, **re-resolve DNS** (not use cached IP)
4. ✅ Detect that the new resolution returns a private IP (192.168.1.1)
5. ✅ **Refuse to connect** to the private address
6. ✅ Log/record the rebinding attempt

### Fail Criteria

The scanner **must not**:
- ❌ Cache the initial DNS response and never re-resolve
- ❌ Connect to 192.168.1.1 after rebinding
- ❌ Treat the private IP as valid because it "belongs to the same hostname"
- ❌ Crash or hang during the rebinding sequence

---

## 6. Evidence Collection

### From DNS Server
- Query log showing sequence: public → private → private...
- Timestamp of each query
- Client IP (should be scanner or test harness)

### From Scanner
- DNS resolution logs showing two different IPs for same hostname
- Policy decision log: "rebinding detected, refusing private address"
- Connection attempt logs (should show no connection to 192.168.1.1)

### From Target
- Access logs showing scanner connected to public IP (or Site 7 EIP)
- No access logs for private IP (since scanner should refuse)

---

## 7. Reset Procedure

```bash
# On the Site 7 instance:
python app/rebind_dns_server.py reset

# Or via reset.sh (which calls this):
./reset.sh
```

The reset script:
1. Stops the DNS rebind service
2. Clears the state file (`/var/lib/site7/rebind-state.json`)
3. Restarts the service
4. Verifies first query returns public IP

---

## 8. Safety Notes

### What This Test Does NOT Do

- ❌ No actual connection to 192.168.1.1 (private IP is never reachable)
- ❌ No network scanning or probing of internal networks
- ❌ No modification of production DNS
- ❌ No real rebinding attack against real infrastructure

### Why It's Safe

1. **Private IP is documentation-only** (192.168.1.1) — not a real internal service
2. **Localhost-only DNS server** — not exposed to network
3. **Deterministic behavior** — no races, no external dependencies
4. **Explicit reset** — state never persists beyond test intent

---

## 9. Integration with expected.yaml

```yaml
- id: SAFE-007
  category: dns_rebinding_safety
  target: rebind-test.paleon-lab-hostile.com
  expect: "scanner re-validates DNS on reconnect; refuses private address after rebinding"
  severity: critical
  claim: observed
```

---

## 10. Troubleshooting

| Issue | Resolution |
|-------|------------|
| DNS server not starting | Check port 5353 not in use: `ss -ulpn | grep 5353` |
| Queries not logged | Check `/var/log/` and stdout for JSON logs |
| State not persisting | Verify `/var/lib/site7/` is writable by site7 user |
| Always returns public IP | Run reset: `python rebind_dns_server.py reset` |
| Route53 record wrong | Verify in AWS console: `aws route53 list-resource-record-sets` |
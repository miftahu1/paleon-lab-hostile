# PALEON TEST SITE 7 — DNS Rebinding Architecture

## Overview

This document describes the DNS rebinding test implementation for Site 7. The test validates that the scanner re-validates DNS resolution on reconnect and refuses connections to private addresses after rebinding.

---

## 1. Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────────┐
│                      SCANNER (External)                             │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      DNS RESOLUTION                                 │
│                                                                     │
│  First lookup (via recursive resolver):                             │
│  rebind-test.paleon-lab-hostile.com  ->  <Site 7 EIP> (public)      │
│                                                                     │
│  Subsequent lookups (TTL=0 forces re-query):                        │
│  rebind-test.paleon-lab-hostile.com  ->  192.168.1.1 (private)      │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    DNS REBIND SERVER                                │
│                                                                     │
│  - Listens on 0.0.0.0:53 (TCP & UDP)                                │
│  - Authoritative for rebind-test.paleon-lab-hostile.com             │
│  - Tracks query count (per client, keyed by IP)                     │
│  - Persists state to /var/lib/site7/rebind-state.json               │
│  - Reset capability: python rebind_dns_server.py reset              │
│  - Runs as site7 user with CAP_NET_BIND_SERVICE                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Test Flow

1. **Scanner resolves hostname** → Gets Site 7 EIP (public)
2. **Scanner connects to public IP** → Reaches Site 7 Nginx
3. **Scanner follows redirect or makes new connection** → Must re-resolve DNS
4. **Second DNS query** → Gets private IP (192.168.1.1)
5. **Scanner should detect rebinding** → Refuse connection to private IP

---

## 2. Implementation Details

### DNS Server (`app/rebind_dns_server.py`)

**Protocol**: Raw UDP/TCP DNS (RFC 1035), no external dependencies

**State Management**:
- Per-client query counters, keyed by client IP (in-memory `OrderedDict`, LRU-evicted at `MAX_CLIENTS`)
- Persisted to `/var/lib/site7/rebind-state.json`
- Survives process restart
- Reset via CLI argument: `python rebind_dns_server.py reset`
- Per-client (not global): each client IP is tracked independently, so one client advancing to "private" never changes what a different, first-time client sees

**Response Logic**:
```python
def get_answer_ip(self, client_ip):
    with self.lock:
        # LRU-evict the oldest client if at capacity and this IP is new
        if client_ip not in self.client_counts and len(self.client_counts) >= MAX_CLIENTS:
            self.client_counts.popitem(last=False)
        count = self.client_counts.get(client_ip, 0)
        # Query #1 (count == 0) -> public EIP (from SITE7_EIP).
        # Every subsequent query -> private 192.168.1.1.
        # The per-client counter is CAPPED at MAX_QUERIES_PER_CLIENT (100) and
        # NEVER wraps, so query #101+ still returns the private address. A client
        # is never handed the public IP again after its very first query.
        answer = PUBLIC_IP if count == 0 else PRIVATE_IP
        self.client_counts[client_ip] = min(count + 1, MAX_QUERIES_PER_CLIENT)
        self.total_a_queries += 1
        self.save_state()
        return answer
```

**TTL**: Always 0 — forces re-resolution on every query

**Flags**: 
- AA (Authoritative Answer) = 1 (0x8400)
- RA (Recursion Available) = 0

**Query Filtering**:
- Only responds to QTYPE=1 (A records)
- Only responds to queries containing `rebind-test.paleon-lab-hostile.com`

**Concurrency**:
- UDP: `ThreadPoolExecutor` (10 workers) gated by a non-blocking `BoundedSemaphore`; excess datagrams are dropped
- TCP: `ThreadPoolExecutor` (10 workers) gated by a non-blocking `BoundedSemaphore`; excess connections are closed

**Logging**: Structured JSON logs for each query:
```json
{
  "timestamp": "2026-09-07T...",
  "level": "INFO",
  "message": "dns_query",
  "query_count": 1,
  "query_name": "rebind-test.paleon-lab-hostile.com",
  "answer_ip": "<EIP>",
  "client_ip": "192.0.2.1"
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

# Malformed HTTP subdomain
malformed-http.paleon-lab-hostile.com.  300  IN  A  <EIP>

# Malformed TLS subdomain
malformed-tls.paleon-lab-hostile.com.  300  IN  A  <EIP>

# NS glue record - ns1 hostname resolves to Site 7 EIP
ns1.paleon-lab-hostile.com.      300  IN  A  <EIP>

# NS delegation: rebind-test subdomain delegated to ns1
rebind-test.paleon-lab-hostile.com.  300  IN  NS  ns1.paleon-lab-hostile.com.
```

**How It Works**:
1. Route53 serves NS record for `rebind-test.paleon-lab-hostile.com` pointing to `ns1.paleon-lab-hostile.com`
2. Resolver queries `ns1.paleon-lab-hostile.com` → gets EIP from A record
3. Resolver queries Site 7 instance on port 53 (TCP/UDP) for `rebind-test.paleon-lab-hostile.com`
4. Site 7 DNS server responds with EIP (1st query) or 192.168.1.1 (subsequent)

**Why This Design?**
- **Deterministic**: No timing races, no third-party DNS
- **Controlled**: Lab owns all DNS infrastructure
- **Authoritative**: Site 7 is the authoritative nameserver for rebind-test
- **Resettable**: Single command restores initial state
- **Observable**: Every query logged with sequence number
- **Standard ports**: Uses standard DNS port 53 (TCP/UDP)

---

## 4. Test Execution

### For Scanner Testing

The scanner resolves `rebind-test.paleon-lab-hostile.com` through standard recursive DNS resolution. The NS delegation in Route53 directs queries to the Site 7 instance on port 53.

### Manual Verification

```bash
# First query - should return public EIP
dig rebind-test.paleon-lab-hostile.com +short
# Expected: <Site 7 EIP>

# Second query - should return private IP
dig rebind-test.paleon-lab-hostile.com +short
# Expected: 192.168.1.1

# Third query - still private (until reset)
dig rebind-test.paleon-lab-hostile.com +short
# Expected: 192.168.1.1

# Direct authoritative query (bypass recursive resolver)
dig @<EIP> rebind-test.paleon-lab-hostile.com +short
# Expected: <EIP> (1st), then 192.168.1.1 (2nd)

# Reset state
python /opt/paleon-site7/deployed_rebind_dns_server.py reset

# Or via reset.sh (which calls this):
./reset.sh

# After reset - back to public
dig rebind-test.paleon-lab-hostile.com +short
# Expected: <Site 7 EIP>
```

---

## 5. Expected Scanner Behavior

### Pass Criteria (SAFE-007)

The scanner **must**:
1. ✅ Resolve `rebind-test.paleon-lab-hostile.com` initially
2. ✅ Connect to the resolved address (public EIP)
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
python /opt/paleon-site7/deployed_rebind_dns_server.py reset

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
- ❌ No modification of production DNS beyond Route53 records
- ❌ No real rebinding attack against real infrastructure

### Why It's Safe

1. **Private IP is documentation-only** (192.168.1.1) — not a real internal service
2. **Authoritative DNS on standard port 53** — standard protocol, no exotic listeners
3. **Deterministic behavior** — no races, no external dependencies
4. **Explicit reset** — state never persists beyond test intent
5. **No IMDS usage** — public IP provided via Terraform/user_data environment variable

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
| DNS server not starting | Check port 53 not in use: `ss -tulpn | grep :53` |
| Queries not logged | Check journalctl: `journalctl -u site7-rebind-dns -f` |
| State not persisting | Verify `/var/lib/site7/` is writable by site7 user |
| Always returns public IP | Run reset: `python /opt/paleon-site7/deployed_rebind_dns_server.py reset` |
| Route53 record wrong | Verify in AWS console: `aws route53 list-resource-record-sets --zone-id <ZONE>` |
| CAP_NET_BIND_SERVICE missing | Check systemd unit: `systemctl show site7-rebind-dns --property=AmbientCapabilities` |
| SITE7_EIP not set | Verify user_data template passes `${public_ip}` and service has Environment=SITE7_EIP |
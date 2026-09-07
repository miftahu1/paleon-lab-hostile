# PALEON SITE 7 — Architecture Documentation

## System Overview

Paleon Site 7 is a hostile adversarial test target deployed as a **single EC2 instance** (Ubuntu 24.04 LTS) in the account's **default VPC**. It runs a small set of Python services behind Nginx and emits hostile HTTP/TLS/DNS stimuli for scanner-resilience validation. It performs no outbound requests of its own.

```
┌──────────────────────────────────────────────────────────────────────┐
│                          AWS (default VPC)                             │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │              EC2 Instance — Ubuntu 24.04 LTS (t3.micro)          │  │
│  │              IMDSv2 required · NO IAM instance profile           │  │
│  │                                                                  │  │
│  │   Public:  22 (admin CIDR) · 53 TCP/UDP · 80 · 443               │  │
│  │                                                                  │  │
│  │   :80  nginx ── 301 ─▶ https                                     │  │
│  │   :443 nginx stream (ssl_preread SNI router)                     │  │
│  │        ├─ malformed-tls.*  ─▶ 127.0.0.1:9998  (raw garbled TLS)  │  │
│  │        ├─ malformed-http.* ─▶ 127.0.0.1:9999  (TLS + bad HTTP)   │  │
│  │        └─ default          ─▶ 127.0.0.1:8443  (nginx HTTPS)      │  │
│  │                                    └─▶ 127.0.0.1:5000  Flask     │  │
│  │                                                                  │  │
│  │   :53  site7-rebind-dns  (authoritative for rebind-test.*)       │  │
│  │                                                                  │  │
│  │   site7-egress-firewall (oneshot): iptables owner-uid REJECT     │  │
│  │        for the 'site7' user → RFC1918 / link-local / ULA         │  │
│  │                                                                  │  │
│  │   /var/lib/site7/rebind-state.json  (only on-disk state)         │  │
│  │   Observations: in-memory deque(maxlen=100)                      │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  Route 53 (zone paleon-lab-hostile.com):                               │
│    A  apex, offscope, malformed-http, malformed-tls, ns1  → EIP        │
│    NS rebind-test → ns1.paleon-lab-hostile.com                         │
└────────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

### 1. Nginx (Ports 80, 443)

- **Port 80** — `301` redirect of every request to `https://$host$request_uri`.
- **Port 443** — a `stream {}` server with `ssl_preread on` inspects the TLS SNI and forwards **raw TCP** (it does not terminate TLS at this layer) to one of three localhost backends:
  - `malformed-tls.*` → `127.0.0.1:9998`
  - `malformed-http.*` → `127.0.0.1:9999`
  - default → `127.0.0.1:8443`
- **Port 8443** — an `http {}` server that terminates TLS for normal traffic and reverse-proxies to Flask at `127.0.0.1:5000` (`proxy_read_timeout 20s`, `proxy_connect_timeout 5s`).

Because malformed traffic is forwarded as raw TCP after `ssl_preread`, Nginx never parses it as HTTP and never "fixes" the malformed bytes.

### 2. Flask Application (Port 5000, localhost only)

Primary hostile endpoint server implementing the SSRF/redirect/resource/observer tests. It binds `127.0.0.1:5000` and is reached only through the Nginx `8443` termination.

**SSRF endpoints** — return `302` redirects whose `Location` points at dangerous destinations (the app never fetches them):
- ECS/Fargate credential endpoint (`169.254.170.2`)
- EC2 IMDS (`169.254.169.254`)
- RFC1918 ranges (`10.0.0.1`, `172.16.0.1`, `192.168.0.1`)
- Loopback (`127.0.0.1`, `[::1]`) and IPv6 ULA (`[fd00::1]`)

**Scope escape** — `302` to `https://offscope.paleon-lab-hostile.com/landing`.

**Redirect loop** — a three-cycle chain `/hostile/redirect-loop/a → b → c → a`, plus `/hostile/self-loop` that redirects to itself.

**Resource exhaustion** — streamed large body (default 10 MB, max 20 MB), slow drip body (10 × 1 KB chunks over the delay, default 5000 ms / max 15000 ms), and a gzip bomb (~10 KB compressed → 10 MB decompressed via `zlib.compressobj(wbits=31)`, streamed).

**Passive safety** — `/hostile/read-only` accepts any method, records the method/path/headers as an observation, and returns `200`.

**Observation store** — in-memory, thread-safe `deque(maxlen=100)`. There are no on-disk observation logs.

### 3. Malformed Server (Ports 9998 & 9999, localhost only)

A single Python process (`site7-malformed-server`) bound to `127.0.0.1`:
- **9998 — malformed TLS (SAFE-004-TLS):** reads a bounded ClientHello over raw TCP, emits a deliberately garbled TLS ServerHello record, and closes. The handshake never completes.
- **9999 — malformed HTTP (SAFE-004):** completes a **real** TLS handshake (using the site's certificate/key), reads a bounded HTTP request, then emits malformed HTTP: `/malformed/chunked` (chunked framing with an invalid chunk token `GARBAGE`), `/malformed/banner` (control bytes in a header value plus a `Content-Length` shorter than the body), or a default length-mismatch response.

Concurrency on each port is bounded by a `BoundedSemaphore` + `ThreadPoolExecutor`; idle connections are reaped after `IDLE_TIMEOUT` (30 s).

### 4. DNS Rebinding Simulator (Port 53 TCP/UDP)

`site7-rebind-dns` is authoritative only for `rebind-test.paleon-lab-hostile.com` (delegated to it by an `NS` record → `ns1` → the EIP). It binds the privileged port 53 as the non-root `site7` user via `CAP_NET_BIND_SERVICE`.

- Query #1 from a given client IP → the instance **EIP** (from `SITE7_EIP`, injected at deploy).
- Query #2+ from that client IP → `192.168.1.1`.
- `TTL=0`, `AA=1`, `RA=0`. Non-A / wrong-class / wrong-name queries are refused or answered NODATA. The per-client counter is capped and never wraps, so a client that has rebound never receives the public IP again.
- State persisted to `/var/lib/site7/rebind-state.json`.

## Data Flow

```
Scanner
  │  HTTPS (SNI decides the path)
  ▼
┌─────────────────────────────┐
│ nginx :443 stream ssl_preread│
└───┬───────────┬───────────┬──┘
    │ default   │ mal-http  │ mal-tls
    ▼           ▼           ▼
 :8443       :9999        :9998
 nginx TLS   TLS +        raw garbled
   │         bad HTTP     ServerHello
   ▼
 :5000 Flask ──▶ in-memory observation deque

Scanner ── DNS ──▶ :53 site7-rebind-dns (public first, then 192.168.1.1)
```

## Security Model

### Threat Model

Site 7 tests scanner behavior; it is not meant to be "secure" in the usual sense. It intentionally emits SSRF redirect bait, resource-exhaustion payloads, malformed HTTP/TLS, and rebinding DNS answers. It deliberately does **not**: make outbound requests, authenticate, read credentials, use a database, or hold real secrets.

### Isolation

- Standalone EC2 instance in the default VPC; no resources shared with other Paleon sites.
- **No IAM instance profile** and **IMDSv2 required**, so there are no role credentials to exfiltrate.
- All application services run as the unprivileged `site7` user.
- Host `iptables`/`ip6tables` `owner --uid-owner site7` rules `REJECT` egress from the `site7` user to `169.254.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`, and `fe80::/10`. A `systemd` oneshot (`site7-egress-firewall.service`, ordered `Before=network-pre.target`) reinstalls them on every boot, so the isolation **persists across reboot**.
- Flask, the Nginx termination, and the malformed backends bind `127.0.0.1` only.

### Scanner Safety Requirements

Scanners MUST:
1. **Inspect, don't follow** — read `Location` headers on 3xx responses but never follow them to private/link-local/off-scope destinations.
2. **Bound resources** — cap response size, total duration (this target holds a connection for at most 15 s and clamps the slow body to 15000 ms), and decompression size.
3. **Parse defensively** — survive malformed HTTP and malformed TLS without crashing or hanging.
4. **Re-validate DNS** — re-resolve on reconnect and refuse the private IP after rebinding.
5. **Terminate cleanly** — handle SIGTERM/SIGKILL without orphan processes.
6. **Stay in scope** — never request `offscope.paleon-lab-hostile.com`.

## State Management

### Observations
- **In-memory** only: a thread-safe `deque(maxlen=100)` inside the Flask process.
- Read via `GET /internal/site7-observation` (localhost only).
- Discarded whenever the Flask service restarts. There are no `.jsonl` files.

### DNS Rebinding State
- Stored as JSON at `/var/lib/site7/rebind-state.json`.
- Reset by `reset.sh` (or `python3 rebind_dns_server.py reset`).

## Service Management

### Systemd Units

| Unit | Description | Notes |
|------|-------------|-------|
| `paleon-site7.service` | Flask app (`127.0.0.1:5000`) | `Restart=always`, runs as `site7` |
| `site7-malformed-server.service` | Malformed TLS/HTTP backends (9998/9999) | `SupplementaryGroups=site7-tls` to read the key |
| `site7-rebind-dns.service` | Authoritative DNS on `:53` | `CAP_NET_BIND_SERVICE`, `SITE7_EIP` injected |
| `site7-egress-firewall.service` | Reboot-persistent egress isolation | `Type=oneshot`, `Before=network-pre.target` |
| `nginx.service` | 80 redirect + 443 SNI router + 8443 termination | — |

### Start Order
1. `site7-rebind-dns.service`
2. `site7-malformed-server.service`
3. `paleon-site7.service`
4. `nginx.service`

`site7-egress-firewall.service` runs at boot before networking comes up and remains active (`RemainAfterExit=yes`).

## Network Ports

| Port | Protocol | Exposure | Service | Purpose |
|------|----------|----------|---------|---------|
| 22 | TCP | Admin CIDR | SSH | Instance management |
| 53 | TCP+UDP | Public | site7-rebind-dns | Authoritative DNS for `rebind-test.*` |
| 80 | TCP | Public | nginx | `301` redirect to HTTPS |
| 443 | TCP | Public | nginx stream | SNI router (`ssl_preread`) |
| 5000 | TCP | localhost | Flask | Main app (proxied via 8443) |
| 8443 | TCP | localhost | nginx | HTTPS termination for default traffic |
| 9998 | TCP | localhost | Malformed TLS | Garbled ServerHello backend |
| 9999 | TCP | localhost | Malformed HTTP | TLS + malformed HTTP backend |

## Deployment Architecture

### Terraform Resources
- **Data sources**: default VPC lookup, latest Canonical Ubuntu 24.04 AMI (overridable via `var.ami_id`).
- **Security group**: ingress for 22 (admin CIDR), 53 TCP/UDP, 80, 443; default egress retained so bootstrap can `apt`/`git` (application egress is restricted on-host).
- **EC2 instance**: `t3.micro` by default, IMDSv2 required, **no IAM instance profile**, encrypted 20 GB gp3 root volume.
- **Elastic IP**: allocated independently, then attached with `aws_eip_association` (no dependency cycle; user_data receives the EIP via `templatefile`).
- **Route 53**: `A` records for apex, offscope, `malformed-http`, `malformed-tls`, and `ns1` (all → EIP); an `NS` record delegating `rebind-test.*` to `ns1`.

### Bootstrap (`user_data.sh.tftpl`)
Idempotent, retry-safe bootstrap that:
1. Updates the system and installs packages (including `libnginx-mod-stream`).
2. Creates the `site7` user and the `site7-tls` key-consumer group.
3. Creates `/var/lib/site7` (rebind state only).
4. Clones the application from GitHub and pins it to `origin/main`.
5. Installs Python dependencies.
6. Creates the `systemd` units.
7. Provisions TLS (`timeout 90s certbot` for the apex + `malformed-http` names; self-signed SAN fallback).
8. Writes the Nginx config (80 redirect, 443 stream router, 8443 termination).
9. Starts the application services and Nginx.
10. Installs and enables the reboot-persistent egress firewall.
11. Runs a hardened health gate (services active, listeners present, health check, key readable) and fails the boot if any check fails.

## Resilience Test Mapping

Each endpoint maps to a resilience test in `expected.yaml`:

| Test ID | Endpoint(s) | Validation Method |
|---------|-------------|-------------------|
| SSRF-001 | `/hostile/ssrf/fargate`, `/hostile/ssrf/fargate-relative` | `302` `Location` contains `169.254.170.2` |
| SSRF-002 | `/hostile/ssrf/imds` | `302` `Location` contains `169.254.169.254` |
| SSRF-003 | `/hostile/ssrf/rfc1918` | `302` `Location` contains an RFC1918 address |
| SSRF-004 | `/hostile/ssrf/localhost`, `ipv6-loopback`, `ipv6-private` | `302` `Location` to `127.0.0.1` / `[::1]` / `[fd00::1]` |
| SAFE-001 | `/hostile/scope-escape` | `302` `Location` to the offscope subdomain |
| SAFE-002 | `/hostile/redirect-loop` (+ `/hostile/self-loop`) | Cycle `a → b → c → a`; scanner must detect the loop |
| SAFE-003 | `/hostile/large-body`, `slow-body`, `gzip-bomb` | Check `Content-Length`, timing, `Content-Encoding` |
| SAFE-004 | `malformed-http.*/malformed/chunked`, `/malformed/banner` | Verify no crash; defensive parsing |
| SAFE-004-TLS | `malformed-tls.*/` | Verify TLS failure is handled without crash/hang |
| SAFE-005 | `/hostile/read-only` | Records the method used; passive observer |
| SAFE-006 | `/hostile/kill-test` | Connection held 15 s; verify clean termination |
| SAFE-007 | `rebind-test.paleon-lab-hostile.com` | Query DNS twice; verify public then private IP |

## Monitoring & Observability

### Logs
- **Systemd journal**: `journalctl -u paleon-site7 -f` (and the other units)
- **Nginx access/error**: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`
- **Bootstrap**: `/var/log/paleon-site7-bootstrap.log`

### Health / Inspection
- `GET /health` → `{"status": "ok", "service": "paleon-site7"}`
- `GET /internal/site7-observation` (localhost) → recent in-memory observations

## Failure Scenarios & Mitigations

| Failure | Detection | Mitigation |
|---------|-----------|------------|
| Flask app crash | `systemd` (`Restart=always`) | Auto-restart within 5 s |
| Malformed server crash | `systemd` | Auto-restart |
| DNS server crash | `systemd` | Auto-restart |
| Missing/invalid `SITE7_EIP` | DNS server hard-fails at startup | Bootstrap health gate fails fast |
| Nginx config error | `nginx -t` in bootstrap | Fail fast in bootstrap |
| Port not listening | `ss` checks in the health gate | Boot fails before "complete" |
| Certbot failure | `timeout 90s` non-fatal | Self-signed SAN certificate fallback |

## Disaster Recovery

- **RPO**: In-memory observations are lost on restart (acceptable for a test target).
- **RTO**: ~5 minutes (`terraform apply` + bootstrap).
- **Backup**: Infrastructure as code; Terraform state per the configured backend.
- **Reset**: `./reset.sh` restarts services and restores the initial DNS-rebinding state.

## Security Hardening

- All services run as the non-root `site7` user.
- No IAM instance profile; IMDSv2 required.
- Encrypted EBS root volume.
- Security group allows only the required inbound ports.
- No secrets in `user_data` or code; the TLS private key is `root:site7-tls` mode `640`.
- Reboot-persistent host egress isolation for the `site7` user.

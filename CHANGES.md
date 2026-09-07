# PALEON TEST SITE 7 — Change Log

## Version 2.0.0 (2026-09-07) — Final Repair, Audit & Documentation Completion

### Fixed
- **DNS rebinding contract hardened** — the per-client query counter is now capped at `MAX_QUERIES_PER_CLIENT` and never wraps, so query #101+ from a client stays private (`192.168.1.1`). A client that has rebound can never be handed the public IP again. (SAFE-007)
- **In-code resilience IDs aligned with `expected.yaml`** — `app/app.py` docstrings now use the canonical IDs (SSRF-001..004, SAFE-001, SAFE-002, SAFE-003, SAFE-005, SAFE-006, SAFE-007); SAFE-004 / SAFE-004-TLS live in `app/malformed_server.py`.
- **Host egress isolation made reboot-persistent** — the `iptables`/`ip6tables` `owner --uid-owner site7` REJECT rules are installed by `site7-egress-firewall.service`, a `systemd` oneshot ordered `Before=network-pre.target`, so isolation survives reboot (previously in-memory only).
- **Removed tracked build artifacts** — untracked `app/__pycache__/*.pyc` and the duplicate `app/requirements.txt` (canonical is `./requirements.txt`); added `.pytest_cache/` to `.gitignore`.

### Changed
- **Documentation rewritten to the final architecture** — `README.md`, `ARCHITECTURE.md`, `DEPLOYMENT.md`, and the `docs/*` set now describe: Ubuntu 24.04 LTS on `t3.micro` in the default VPC; Nginx `stream` + `ssl_preread` SNI routing on 443 to localhost backends (`8443` termination, `9998` malformed TLS, `9999` malformed HTTP); DNS on port 53; in-memory observation store; and the `20 MB / 15 000 ms / 15 s / 10 MB` resource ceilings. Purged the stale container-based deployment model, the previous base-OS references, the retired internal port numbers, and placeholder public IPs.
- **`verify.sh` rewritten** — malformed HTTP and malformed TLS are now checked by capturing raw response bytes (no `curl | grep "HTTP/"`), and the DNS rebinding contract is verified directly against the authoritative server.
- **`validate.sh` hardened** — added a check that the egress rules are reboot-persistent (`site7-egress-firewall` unit) and removed a documentation false-positive.

### Deployment Readiness
- Certbot TLS provisioning integrated in bootstrap (`timeout 90s certbot` for the apex + `malformed-http` names) with a self-signed SAN fallback; the DNS-rebinding and malformed-TLS names are intentionally excluded from issuance.
- Bootstrap ends with a hardened health gate (service state, listeners, health check, key permissions) that fails the boot on any error.

---

## Version 1.0.0 (2026-09-04) — Initial Release

### Added
- **Complete hostile test target implementation** for Paleon scanner resilience validation
- **Flask application** (`app/app.py`) with test endpoints covering:
  - 7 SSRF redirect endpoints (Fargate, Fargate-relative, IMDS, RFC1918, localhost, IPv6 loopback, IPv6 ULA)
  - DNS rebinding info endpoint
  - Scope escape endpoint (off-scope redirect)
  - Redirect loop endpoints (3-cycle `a → b → c → a` + self-loop)
  - Large body streaming endpoint (default 10 MB, max 20 MB)
  - Slow body streaming endpoint (default 5000 ms, max 15000 ms)
  - Gzip bomb endpoint (~10 KB compressed → ~10 MB decompressed)
  - Read-only observer endpoint (records all HTTP methods)
  - Kill test endpoint (15 s connection hold)
  - Internal observation endpoint (localhost only)
- **Malformed protocol server** (`app/malformed_server.py`), localhost-only backends behind Nginx SNI:
  - Malformed HTTP over real TLS on `127.0.0.1:9999` (invalid chunked encoding, control-byte/length-mismatch banner)
  - Malformed TLS on `127.0.0.1:9998` (garbled ServerHello; handshake never completes)
  - Connection cap (10 concurrent per port), idle connection reaper (30 s timeout)
- **DNS rebinding server** (`app/rebind_dns_server.py`):
  - Authoritative DNS on TCP+UDP 53
  - First query returns the instance EIP (injected via `SITE7_EIP`)
  - Subsequent queries return the private IP (`192.168.1.1`)
  - TTL=0 for forced re-resolution
  - File-based state persistence and CLI reset
- **Terraform infrastructure** (`terraform/`):
  - Security group (HTTP/HTTPS and DNS from `0.0.0.0/0`, SSH from admin IP only)
  - EC2 instance with **no IAM role**, IMDSv2 required
  - Elastic IP allocated then associated (no dependency cycle)
  - Route 53 records: `A` for apex, offscope, `malformed-http`, `malformed-tls`, `ns1`; `NS` delegating `rebind-test` to `ns1`
  - All resources prefixed with `paleon-site7`
- **Scripts**: `reset.sh` (state reset), `validate.sh` (static validation), `verify.sh` (runtime verification), `terraform/user_data.sh.tftpl` (EC2 bootstrap)
- **Documentation**: `README.md`, `ARCHITECTURE.md`, `DEPLOYMENT.md`, `expected.yaml`, and the `docs/` set (threat model, test matrix, isolation, DNS rebinding, resource exhaustion, malformed protocols, port map)

### Design Decisions
1. **No IAM role on EC2** — zero credential access from the instance
2. **Separate servers for malformed/DNS tests** — isolated from the main web app
3. **Localhost-only binding** for internal servers (5000, 8443, 9998, 9999); DNS on public 53
4. **Streaming responses** — never allocates a full hostile payload in RAM
5. **Structured JSON logging** — excludes sensitive fields automatically
6. **Resource bounds enforced** — `MAX_BODY_SIZE=20 MB`, `MAX_DELAY=15000 ms`, kill hold 15 s, gzip decompressed 10 MB
7. **No outbound network calls** from application code

### Security Controls
- No hardcoded credentials, AWS keys, or secrets; no private keys committed
- No `.env` or `.tfstate` files committed
- All shell scripts use `set -euo pipefail`
- No `curl -L` or outbound requests in verification scripts
- Input validation on all configurable parameters

### Test Coverage
| Test ID | Category | Implemented |
|---------|----------|-------------|
| SSRF-001 | SSRF Safety | ✅ `/hostile/ssrf/fargate`, `/hostile/ssrf/fargate-relative` |
| SSRF-002 | SSRF Safety | ✅ `/hostile/ssrf/imds` |
| SSRF-003 | SSRF Safety | ✅ `/hostile/ssrf/rfc1918` |
| SSRF-004 | SSRF Safety | ✅ `/hostile/ssrf/localhost`, `ipv6-loopback`, `ipv6-private` |
| SAFE-001 | Scope Safety | ✅ `/hostile/scope-escape` |
| SAFE-002 | Redirect Safety | ✅ `/hostile/redirect-loop/*`, `/hostile/self-loop` |
| SAFE-003 | Resource Safety | ✅ `/hostile/large-body`, `slow-body`, `gzip-bomb` |
| SAFE-004 | Parser Safety | ✅ `malformed-http.*/malformed/chunked`, `/malformed/banner` |
| SAFE-004-TLS | Parser Safety | ✅ `malformed-tls.*` (garbled ServerHello) |
| SAFE-005 | Passive Safety | ✅ `/hostile/read-only` |
| SAFE-006 | Termination Safety | ✅ `/hostile/kill-test` |
| SAFE-007 | DNS Rebind Safety | ✅ `rebind-test.paleon-lab-hostile.com` + DNS server |

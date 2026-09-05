# PALEON TEST SITE 7 — Change Log

## Version 1.0.0 (2026-09-04) — Initial Release

### Added
- **Complete hostile test target implementation** for Paleon scanner resilience validation
- **Flask application** (`app/app.py`) with 22 test endpoints covering:
  - 7 SSRF test endpoints (Fargate, IMDS, RFC1918, localhost, IPv6 loopback, IPv6 private)
  - DNS rebinding test endpoint
  - Scope escape endpoint (off-scope redirect)
  - 4 redirect loop endpoints (3-cycle + self-loop)
  - Large body streaming endpoint (configurable up to 50MB)
  - Slow body streaming endpoint (configurable delay up to 30s)
  - Gzip bomb endpoint (~20KB compressed → ~10MB decompressed)
  - 3 malformed response endpoints (chunked, TLS placeholder, junk banner)
  - Read-only observer endpoint (logs all HTTP methods)
  - Kill test endpoint (30s connection hold)
  - Internal observation endpoint (localhost only)
- **Malformed protocol server** (`app/malformed_server.py`):
  - Invalid chunked encoding responses
  - Junk HTTP banner responses
  - Connection cap (10 concurrent)
  - Idle connection reaper (30s timeout)
- **DNS rebinding server** (`app/rebind_dns_server.py`):
  - Authoritative DNS on UDP 5353
  - First query returns public IP (93.184.216.34)
  - Subsequent queries return private IP (192.168.1.1)
  - TTL=0 for forced re-resolution
  - File-based state persistence
  - Reset capability via CLI
- **Terraform infrastructure** (`terraform/`):
  - Local backend (no S3)
  - Security group (HTTP/HTTPS from 0.0.0.0/0, SSH from admin IP only)
  - EC2 instance with NO IAM role
  - Elastic IP for stable DNS
  - Route53 records for 3 hostnames
  - All resources prefixed with `paleon-site7`
- **Scripts**:
  - `reset.sh` - Safe state reset (stops services, clears observations, restarts)
  - `validate.sh` - Static validation (syntax, file existence, no secrets, endpoints coverage)
  - `verify.sh` - Runtime verification (does NOT follow redirects)
  - `user_data.sh` - EC2 bootstrap (to be created)
- **Documentation**:
  - `README.md` - Overview, test matrix, isolation model, pass/fail criteria
  - `ARCHITECTURE.md` - System diagram, components, network topology, port map
  - `DEPLOYMENT.md` - Full deployment instructions, troubleshooting, cost estimates
  - `expected.yaml` - Resilience test definitions (SSRF-001 through SAFE-007)
  - `docs/threat-model.md` - Threat model, assets, trust boundaries
  - `docs/test-matrix.md` - Detailed test matrix with evidence requirements
  - `docs/isolation.md` - Network isolation model
  - `docs/dns-rebinding.md` - DNS rebind architecture
  - `docs/resource-exhaustion.md` - Resource exhaustion test design
  - `docs/malformed-protocols.md` - Malformed protocol test design
  - `docs/port-map.md` - Port allocation and justification

### Design Decisions
1. **No IAM role on EC2** - Ensures zero credential access from instance
2. **Local Terraform backend** - No shared state, isolated lab environment
3. **Separate servers for malformed/DNS tests** - Isolated from main web app
4. **Localhost-only binding** for internal test servers (9999, 5353)
5. **Streaming responses** - Never allocates full payload in RAM
6. **Structured JSON logging** - Excludes sensitive fields automatically
7. **Resource bounds enforced** - MAX_BODY_SIZE=50MB, MAX_DELAY=30s
8. **No outbound network calls** from application code

### Security Controls
- No hardcoded credentials, AWS keys, or secrets
- No private keys in repository
- No `.env` or `.tfstate` files committed
- All shell scripts use `set -euo pipefail` with safe increment patterns
- No `curl -L` or outbound requests in verification scripts
- Input validation on all configurable parameters

### Test Coverage
| Test ID | Category | Implemented |
|---------|----------|-------------|
| SSRF-001 | SSRF Safety | ✅ `/hostile/ssrf/fargate` |
| SSRF-002 | SSRF Safety | ✅ `/hostile/ssrf/imds` |
| SSRF-003 | SSRF Safety | ✅ `/hostile/ssrf/rfc1918` |
| SSRF-004 | SSRF Safety | ✅ `/hostile/ssrf/localhost`, `/hostile/ssrf/ipv6-loopback`, `/hostile/ssrf/ipv6-private` |
| SAFE-001 | Scope Safety | ✅ `/hostile/scope-escape` |
| SAFE-002 | Redirect Safety | ✅ `/hostile/redirect-loop/*`, `/hostile/self-loop` |
| SAFE-003 | Resource Safety | ✅ `/hostile/large-body`, `/hostile/slow-body`, `/hostile/gzip-bomb` |
| SAFE-004 | Parser Safety | ✅ `/hostile/malformed/chunked`, `/hostile/malformed/banner` |
| SAFE-005 | Passive Safety | ✅ `/hostile/read-only` |
| SAFE-006 | Termination Safety | ✅ `/hostile/kill-test` |
| SAFE-007 | DNS Rebind Safety | ✅ `rebind-test.paleon-lab-hostile.com` + DNS server |

### Known Limitations
1. **No TLS certificates provisioned** - Uses self-signed or requires manual certbot setup
2. **No `user_data.sh` template** - Referenced by Terraform but not yet created
3. **No Docker Compose file** - Referenced in README but not yet created
4. **Route53 zone must exist** - Not created by Terraform
5. **Verification script assumes deployed domain** - Local testing requires modifications

### Next Steps
- [ ] Create `terraform/scripts/user_data.sh.tftpl` for EC2 bootstrap
- [ ] Create `docker-compose.yml` for local development
- [ ] Add certbot integration for valid TLS
- [ ] Create test fixtures for malformed TLS listener
- [ ] Run full validation and verification suite
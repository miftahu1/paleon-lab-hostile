# PALEON SITE 7 — Documentation Index

This directory contains detailed documentation for the hostile test target.

## Documents

| File | Description |
|------|-------------|
| [README.md](README.md) | This index |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture and design |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Deployment instructions |
| [API.md](API.md) | API endpoint reference |
| [OPERATIONS.md](OPERATIONS.md) | Operations and maintenance guide |
| [test-matrix.md](test-matrix.md) | Test case matrix |
| [resource-exhaustion.md](resource-exhaustion.md) | Resource exhaustion endpoint details |
| [threat-model.md](threat-model.md) | Threat model and security analysis |
| [isolation.md](isolation.md) | Isolation guarantees |
| [malformed-protocols.md](malformed-protocols.md) | Malformed HTTP/TLS protocol details |
| [port-map.md](port-map.md) | Port allocation map |
| [dns-rebinding.md](dns-rebinding.md) | DNS rebinding implementation details |

## Quick Links

- **Main README**: [../README.md](../README.md)
- **Expected Schema**: [../expected.yaml](../expected.yaml)
- **Validation Script**: [../validate.sh](../validate.sh)
- **Verification Script**: [../verify.sh](../verify.sh)
- **Reset Script**: [../reset.sh](../reset.sh)
- **Bootstrap Script**: [../terraform/user_data.sh.tftpl](../terraform/user_data.sh.tftpl)
- **Terraform Config**: [../terraform/main.tf](../terraform/main.tf)

## Resilience Tests Summary

See [../expected.yaml](../expected.yaml) for the complete resilience test schema with 12 tests across 8 categories:
- **SSRF Safety** (4 tests, critical)
- **Scope Safety** (1 test, high)
- **Redirect Safety** (1 test, high)
- **Resource Safety** (1 test, 3 targets, high)
- **Parser Safety** (2 tests, high)
- **Passive Safety** (1 test, high)
- **Termination Safety** (1 test, medium)
- **DNS Rebinding Safety** (1 test, critical)

## Service Ports

| Service | Port(s) | Protocol |
|---------|---------|----------|
| nginx | 80, 443 | TCP |
| Flask App | 5000 | TCP (internal, 127.0.0.1) |
| Malformed TLS | 9998 | TCP (internal, 127.0.0.1) |
| Malformed HTTP | 9999 | TCP (internal, 127.0.0.1) |
| Rebinding DNS | 53 | TCP/UDP |

## Data Directories

| Path | Purpose |
|------|---------|
| /var/lib/site7/rebind-state.json | DNS rebinding state (only on-disk state) |

Endpoint observations are held **in-memory** (a bounded `deque(maxlen=100)` inside the Flask process) and read via `GET /internal/site7-observation`; they are discarded on restart. There are no on-disk observation logs and no temp directory.
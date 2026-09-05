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

## Quick Links

- **Main README**: [../README.md](../README.md)
- **Expected Schema**: [../expected.yaml](../expected.yaml)
- **Validation Script**: [../validate.sh](../validate.sh)
- **Verification Script**: [../verify.sh](../verify.sh)
- **Reset Script**: [../reset.sh](../reset.sh)
- **Bootstrap Script**: [../user_data.sh](../user_data.sh)
- **Terraform Config**: [../main.tf](../main.tf)

## Resilience Tests Summary

See [../expected.yaml](../expected.yaml) for the complete resilience test schema with 11 tests across 6 categories:
- **SSRF Safety** (4 tests, critical)
- **Scope Safety** (1 test, high)
- **Redirect Safety** (1 test, high)
- **Resource Safety** (3 tests, high)
- **Parser Safety** (2 tests, high)
- **Passive Safety** (1 test, high)
- **Termination Safety** (1 test, medium)
- **DNS Rebinding Safety** (1 test, critical)

## Service Ports

| Service | Port(s) | Protocol |
|---------|---------|----------|
| nginx | 80, 443 | TCP |
| Flask App | 5000 | TCP |
| Malformed Server | 5001 | TCP |
| Rebinding HTTP | 5002 | TCP |
| Rebinding DNS | 8053 | UDP |

## Data Directories

| Path | Purpose |
|------|---------|
| /var/lib/site7/observations/ | JSONL observation logs |
| /var/lib/site7/rebind-state.json | DNS rebinding state |
| /var/lib/site7/temp/ | Temporary files |
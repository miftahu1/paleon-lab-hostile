# Operations reference

This file documents expected service operations; repository review remains local-only and must not start Site 7 or deploy resources.

Services are `site7-egress-firewall`, `paleon-site7`, `site7-malformed-server`, `site7-rebind-dns`, and `nginx`. Firewall is enabled across reboot and required/ordered before every Site 7 workload, including Nginx. Confirm service ordering and firewall state before any future approved operation.

The DNS state can be reset by the existing local operator reset script when operating an authorized deployment; this returns per-client A answers to first-query public followed by private. DNS logs include timestamps, source IP, qname, qtype, answer, and per-client plus total counters. Do not interpret the recursive resolver's source IP as the scanner IP.

For HTTP operations, every behavior is tied to its own hostname and applies at arbitrary/fixed paths. Public HTTPS must return 404 for `/internal/site7-observation`; local operator access is through `127.0.0.1:5000`. Slow-drip uses one byte every 10 seconds and at most 60 bytes, with public Nginx streaming and finite 660 second idle timeouts.

See `expected.yaml` for findings and evidence expectations, `docs/DEPLOYMENT.md` for account/region/configuration requirements, and `docs/isolation.md` for egress policy.

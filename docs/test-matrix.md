# Validation matrix

The authoritative scanner outcome details (hostname, stimulus, expected behavior, finding flag, severity, evidence, and termination) live in [`expected.yaml`](../expected.yaml). Severity labels there are expectations only, not live observations. No product severity is claimed as observed before an authorized scan.

| ID | Host | Stimulus |
|---|---|---|
| SSRF-001 | fargate | Redirect to container metadata address |
| SSRF-002 | imds | Redirect to EC2 metadata address |
| SSRF-003 | rfc1918 | Redirect to private IPv4 |
| SSRF-004 | loopback | Redirect to IPv4 loopback |
| SSRF-004-IPV6 | ipv6 | Redirect to IPv6 ULA |
| SAFE-001 | offscope-redirect | Redirect to `OFFSCOPE_DOMAIN` |
| SAFE-002 | redirect-loop | Three-host-local path cycle |
| SAFE-002-SELF | self-loop | Self redirect |
| SAFE-003 | large-body | Bounded streamed body |
| SAFE-003-SLOW | slow-body | Delayed chunks |
| SAFE-003-GZIP | gzip-body | Bounded gzip expansion |
| SAFE-004 | malformed-http | Malformed HTTP over valid TLS |
| SAFE-004-TLS | malformed-tls | Invalid TLS handshake bytes |
| SAFE-005 | observer | Passive method observation; server accepts every method |
| SAFE-006 | kill-test | 15 second held response |
| SAFE-007 | rebind-test | Public first A answer, then private answers |
| SAFE-008 | ftp-redirect | Redirect to FTP scheme |
| SAFE-009 | slow-drip | One byte every 10s, max 60 bytes / 10 minutes |
| SAFE-010-TLS | slow-tls | Delayed handshake |

Normal expected findings are separately recorded in `expected.yaml`: public authoritative DNS on TCP/UDP 53, absent SPF and DMARC, missing common security headers on Flask responses, HTTP-to-HTTPS redirect, and TLS protocol information. Missing MX is an expected informational check only where DNS confirms no MX/no mail infrastructure; the zone is not mutated by this validation. Safety invariants are listed separately from findings.

Local tests cover dedicated hosts, fixed-path behavior, malformed wire responses, DNS Stage A and honest Stage B reporting, off-scope redirects without following, streaming over public 443, and public observation endpoint isolation. Run `python3 test_all_endpoints.py <EIP>` only when a live target and EIP are explicitly supplied for a separately approved validation. It must not guess an EIP.

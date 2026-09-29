# Validation matrix

The authoritative scanner outcome details (hostname, stimulus, expected behavior, finding flag, severity, evidence, and termination) live in [`expected.yaml`](../expected.yaml). Severity labels there are expectations only, not live observations. No product severity is claimed as observed before an authorized scan.

| ID | Host | Stimulus |
|---|---|---|
| SSRF-001 | fargate | Redirect to container metadata address |
| SSRF-002 | imds | Redirect to EC2 metadata address |
| SSRF-003 | rfc1918 | Redirect to private IPv4 |
| SSRF-004 | loopback | Redirect to IPv4 loopback |
| SSRF-004-IPV6 | ipv6 | Redirect to IPv6 ULA |
| SAFE-001 | offscope-redirect | Redirect to separately served `OFFSCOPE_DOMAIN`; verify zero scan-attributable sink requests during the recorded scan window |
| SAFE-002 | redirect-loop | Three-host-local path cycle |
| SAFE-002-SELF | self-loop | Self redirect; stop at four repeats of same URL or ten redirects total, whichever comes first |
| SAFE-003 | large-body | Bounded streamed body |
| SAFE-003-SLOW | slow-body | Delayed chunks |
| SAFE-003-GZIP | gzip-body | Metadata inspection; response body is not decompressed |
| SAFE-004 | malformed-http | Malformed HTTP over valid TLS |
| SAFE-004-TLS | malformed-tls | Invalid TLS handshake bytes |
| SAFE-005 | observer | Passive method observation; server accepts every method |
| SAFE-006 | kill-test | 15 second held response; skipped until scan-stop control is available |
| SAFE-007 | rebind-test | Initial public A answer is vetted, pinned, and used without re-resolution |
| SAFE-008 | ftp-redirect | Redirect to FTP scheme |
| SAFE-009 | slow-drip | One byte every 10s, max 60 bytes / 10 minutes |
| SAFE-010-TLS | slow-tls | Delayed handshake |

Normal expected findings are separately recorded in `expected.yaml`: exposed TCP/53 only (Paleon scans TCP; do not expect UDP/53), missing SPF and DMARC at Medium when there is no MX/mail infrastructure, security-header findings only for final 200-range responses, HTTP-to-HTTPS redirect, and TLS protocol information. Redirect responses do not create security-header findings. The `.com` registrar transfer-lock check records the live ON/OFF state from registrar/registration data, never DNS, and uses that observed state for scoring. Missing MX is an expected informational check only where active DNS confirms no MX/no mail infrastructure; the zone is not mutated by this validation. The observer returns HTTP 200 for every path, so guessed exposed-file paths such as `/.env` and `/.git/config` (and similar paths) must not be reported as exposed files; any such finding is a false positive. SAFE-001 prerequisites, pass condition, and log correlation procedure are in [Deployment configuration](DEPLOYMENT.md#off-scope-safe-001-sink). SAFE-006 remains in the answer key but is skipped until Paleon provides a running-scan stop control; execute it once that control is available. Safety invariants are listed separately from findings.

Local tests cover dedicated hosts, fixed-path behavior, malformed wire responses, DNS Stage A and honest Stage B reporting, off-scope redirects without following, streaming over public 443, and public observation endpoint isolation. Run `python3 test_all_endpoints.py <EIP>` only when a live target and EIP are explicitly supplied for a separately approved validation. It must not guess an EIP.

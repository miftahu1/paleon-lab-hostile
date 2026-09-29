# Change log

## Current repository review

- Added a parameterized, isolated SAFE-001 off-scope Nginx sink with separate HTTP-01 webroot, required trusted ACME certificate, and User-Agent-bearing access log; documented external DNS and scan-window evidence.
- Made trusted off-scope ACME issuance a bootstrap health prerequisite; issuance failure leaves the sink unavailable and fails the health gate instead of using self-signed TLS.
- Aligned scanner answer-key expectations with current Paleon behavior: standard self-redirect limits, no gzip body decompression, DNS address pinning, TCP-only port scanning, final-200-only security-header checks, and Medium SPF/DMARC severity without mail infrastructure.
- Recorded the live registrar transfer-lock check requirements and marked SAFE-006 skipped until a running-scan stop control is available.
- Clarified that guessed exposed-file findings on the uniform-200 observer are false positives.

- Documented the non-crawling scanner model: fixed paths, dedicated hostname per stimulus, Host-header dispatch, and response consistency across paths.
- Added FTP redirect, bounded slow-drip and slow-TLS fixtures, and retained malformed protocol fixtures.
- Ensured Nginx streams hostile responses without proxy buffering, sets finite 660 second timeouts, and blocks the operator observation endpoint on public HTTPS.
- Ordered and required the reply-only egress firewall before Site 7 units; firewall rules persist through the enabled systemd oneshot.
- Added expected AWS account ID guard/output and made the second off-scope domain operator-configured instead of inventing a domain.
- Kept DNS zone-transfer fixture design deferred and inactive.

## Earlier history

Historical implementation notes are intentionally omitted where they describe superseded endpoint routing or obsolete AWS regions. Current behavior is documented in the README and `docs/`.

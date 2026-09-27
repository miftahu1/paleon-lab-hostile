# Change log

## Current repository review

- Documented the non-crawling scanner model: fixed paths, dedicated hostname per stimulus, Host-header dispatch, and response consistency across paths.
- Added FTP redirect, bounded slow-drip and slow-TLS fixtures, and retained malformed protocol fixtures.
- Ensured Nginx streams hostile responses without proxy buffering, sets finite 660 second timeouts, and blocks the operator observation endpoint on public HTTPS.
- Ordered and required the reply-only egress firewall before Site 7 units; firewall rules persist through the enabled systemd oneshot.
- Added expected AWS account ID guard/output and made the second off-scope domain operator-configured instead of inventing a domain.
- Kept DNS zone-transfer fixture design deferred and inactive.

## Earlier history

Historical implementation notes are intentionally omitted where they describe superseded endpoint routing or obsolete AWS regions. Current behavior is documented in the README and `docs/`.

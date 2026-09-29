# Deployment configuration reference

Repository review is local-only. This guide does not authorize deployment, AWS resource creation, DNS updates, certificate issuance, Paleon verification, or a live scan.

Site 7 is deployed only in AWS region `eu-west-2`. Select the same lab account used for Sites 1–6, never the Paleon SaaS/application account. The ID is intentionally unknown. The operator must explicitly supply the Sites 1–6 lab account ID through required `expected_aws_account_id`; Terraform checks it against `aws_caller_identity.current` before creating Site 7 resources. Review the `current_aws_account_id` output too. No credentials are stored here.

Operators provide `admin_ip`, `key_name`, `route53_zone_id`, `expected_aws_account_id`, and `offscope_domain` in an untracked local `terraform.tfvars` or through `-var` flags. `offscope_domain` must be a separately registered domain and must never be verified in Paleon or added to business context. It is used solely as SAFE-001's redirect destination. No domain is invented or hard-coded.

For the current validation, the operator-supplied value is `papercomet.in`; the application and Terraform remain parameterized through `offscope_domain` / `OFFSCOPE_DOMAIN`. Keep it outside Paleon's business context and never verify it in Paleon.

The normal Terraform SAN list includes the apex and every entry of `hostile_subdomains`, including malformed HTTP/TLS, offscope-redirect, slow-tls, ftp-redirect, and slow-drip. It omits `rebind-test` because alternating DNS answers interfere with certificate validation, and omits `ns1` because it is DNS infrastructure only. The separately registered `OFFSCOPE_DOMAIN` is not an entry in `hostile_subdomains` and is never added to this certificate.

### Off-scope SAFE-001 sink

Before ACME validation, configure working public DNS with an **A** record for `OFFSCOPE_DOMAIN` at that domain's own registrar/DNS provider pointing to the Site 7 Elastic IP. Do not create this record in the `paleon-lab-hostile.com` Route 53 zone: the domains are separately registered and the off-scope domain's DNS is externally managed. Confirm public resolution and HTTP reachability on port 80 first. Terraform does not create DNS records for `OFFSCOPE_DOMAIN`, a second account, an instance, or an EIP.

Bootstrap writes a separate Nginx server configuration for exactly `OFFSCOPE_DOMAIN`; it is not added to `hostile_subdomains` or the ordinary hostile certificate SAN list. Port 80 serves `/.well-known/acme-challenge/` from `/var/www/site7-acme` and redirects other paths to HTTPS only after certificate readiness. Before readiness, non-challenge HTTP returns 503 and the dedicated HTTPS listener is absent. After readiness, HTTPS is routed through the existing public SNI listener to an isolated Nginx server block on `127.0.0.1:8444`, which returns a fixed plain-text sink response and never proxies to Flask. It explicitly returns 404 for `/internal/site7-observation`.

Certbot requests a distinct certificate named `site7-offscope-<domain-slug>` using HTTP-01/webroot while normal Nginx is active. Its live files are under `/etc/letsencrypt/live/site7-offscope-<domain-slug>/`; the certificate contains only `OFFSCOPE_DOMAIN`. Successful issuance and Nginx activation of this dedicated trusted certificate are deployment prerequisites for SAFE-001 readiness. If issuance or activation fails, no self-signed certificate is substituted: bootstrap logs a clear SAFE-001 fatal error, serves HTTP 503 for the sink, omits its dedicated HTTPS listener, and fails the final health gate. That failure does not alter the normal hostile-host certificate behavior. Renewed certificates trigger an Nginx reload.

HTTP and HTTPS requests for the off-scope host write to `/var/log/nginx/<domain-slug>_access.log`, separate from `/var/log/nginx/access.log`. The slug is derived from the configured hostname by lowercasing it and replacing characters outside `a-z`, digits, dot, and hyphen with `_`; for `papercomet.in`, the path is `/var/log/nginx/papercomet.in_access.log`. The dedicated format records ISO timestamp, source IP, request method, host, request URI/target, HTTP status, request time, and User-Agent. Preserve this log for the entire observation window. User-Agent is useful for correlation, but no particular value proves a request came from Paleon by itself.

#### SAFE-001 scan-window evidence procedure

1. Before starting, confirm the public A record resolves to the Site 7 EIP, the host is reachable, its dedicated certificate and Nginx block are active, and its dedicated access log is being written. Confirm `OFFSCOPE_DOMAIN` is absent from Paleon business context and is not verified in Paleon.
2. Start log observation before launching the scan. Immediately before starting the Site 7 scan, record the exact UTC timestamp as `SCAN_START_UTC`.
3. Immediately after the scan finishes, record the exact UTC timestamp as `SCAN_END_UTC`. Do not fill these values in advance or invent them in repository records.
4. Preserve the complete dedicated access log for that interval. Compare entries in `[SCAN_START_UTC, SCAN_END_UTC]` using source IP, path, request timing, User-Agent, and exact timestamps against Paleon-side scan/scope evidence.
5. SAFE-001 passes only when zero requests attributable to the Paleon scan reached `OFFSCOPE_DOMAIN`. Unrelated internet/background requests or other scanners do not fail the check; investigate them separately. The required pass conditions and evidence are also in `expected.yaml`.

Bootstrap writes/starts the firewall before Site 7 units. Firewall service is ordered before `network-pre.target`; all application/DNS/raw protocol services and Nginx require and follow it. The enabled oneshot reinstalls rules at boot. Public Nginx HTTPS blocks `/internal/site7-observation`; operators use the local Flask listener directly. Streaming proxy timeouts are finite (660 seconds), with proxy buffering disabled.

## Paleon answer-key behavior

Paleon follows self-redirects under the standard Python redirect limits and stops when the same URL has repeated four times or ten redirects total have been reached, whichever occurs first. Its current probes may inspect gzip response metadata but do not decompress or expand response bodies. DNS rebinding protection resolves once, vets and pins the resulting address, and connects only to that address; it does not re-resolve before connecting again. The SAFE-007 pass condition is zero connections to `192.168.1.1` with evidence that the initial public address was pinned and used.

Paleon scans TCP only, so the expected exposed DNS finding is TCP/53; UDP/53 is not an expected exposed-port finding. Missing SPF and DMARC are Medium when no MX/mail infrastructure exists. Security-header findings (HSTS, CSP, X-Frame-Options, and X-Content-Type-Options) apply only to final responses in the 200 range; redirects do not create those findings. The observer returns HTTP 200 for every path, so guessed paths such as `/.env` and `/.git/config` must not produce exposed-file findings. Record the `.com` registrar transfer-lock state for `paleon-lab-hostile.com` from live registrar/registration data, never infer it from DNS, and score using the observed ON/OFF state. SAFE-006 is retained but skipped until Paleon provides a running-scan stop control; execute it once available.

# Deployment configuration reference

Repository review is local-only. This guide does not authorize deployment, AWS resource creation, DNS updates, certificate issuance, Paleon verification, or a live scan.

Site 7 is deployed only in AWS region `eu-west-2`. Select the same lab account used for Sites 1–6, never the Paleon SaaS/application account. The ID is intentionally unknown. The operator must explicitly supply the Sites 1–6 lab account ID through required `expected_aws_account_id`; Terraform checks it against `aws_caller_identity.current` before creating Site 7 resources. Review the `current_aws_account_id` output too. No credentials are stored here.

Operators provide `admin_ip`, `key_name`, `route53_zone_id`, `expected_aws_account_id`, and `offscope_domain` in an untracked local `terraform.tfvars` or through `-var` flags. `offscope_domain` must be a separately registered domain and must never be verified in Paleon or added to business context. It is used solely as SAFE-001's redirect destination. No domain is invented or hard-coded.

The Terraform SAN list includes apex and all ordinary hostile stimulus hosts, including malformed HTTP/TLS, offscope-redirect, slow-tls, ftp-redirect, and slow-drip. It omits rebind-test because alternating DNS answers interfere with certificate validation, and omits ns1 because it is DNS infrastructure only.

Bootstrap writes/starts the firewall before Site 7 units. Firewall service is ordered before `network-pre.target`; all application/DNS/raw protocol services and Nginx require and follow it. The enabled oneshot reinstalls rules at boot. Public Nginx HTTPS blocks `/internal/site7-observation`; operators use the local Flask listener directly. Streaming proxy timeouts are finite (660 seconds), with proxy buffering disabled.

## Paleon answer-key behavior

Paleon follows self-redirects under the standard Python redirect limits and stops when the same URL has repeated four times or ten redirects total have been reached, whichever occurs first. Its current probes may inspect gzip response metadata but do not decompress or expand response bodies. DNS rebinding protection resolves once, vets and pins the resulting address, and connects only to that address; it does not re-resolve before connecting again. The SAFE-007 pass condition is zero connections to `192.168.1.1` with evidence that the initial public address was pinned and used.

Paleon scans TCP only, so the expected exposed DNS finding is TCP/53; UDP/53 is not an expected exposed-port finding. Missing SPF and DMARC are Medium when no MX/mail infrastructure exists. Security-header findings (HSTS, CSP, X-Frame-Options, and X-Content-Type-Options) apply only to final responses in the 200 range; redirects do not create those findings. The observer returns HTTP 200 for every path, so guessed paths such as `/.env` and `/.git/config` must not produce exposed-file findings. Record the `.com` registrar transfer-lock state for `paleon-lab-hostile.com` from live registrar/registration data, never infer it from DNS, and score using the observed ON/OFF state. SAFE-006 is retained but skipped until Paleon provides a running-scan stop control; execute it once available.

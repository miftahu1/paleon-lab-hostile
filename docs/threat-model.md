# Threat model

Site 7 validates whether a scanner remains within scope when it encounters hostile redirect destinations, rebinding DNS, parser-invalid protocol data, and resource-exhaustion stimuli. The scanner discovers hosts and fetches a fixed path set, rather than crawling links; each stimulus therefore has a dedicated hostname and all paths on it produce the corresponding behavior.

The target is passive. It only emits responses and DNS answers, never follows redirects or sends arbitrary third-party requests. It has no IAM instance profile and no real credentials or malware. Host egress denies new `site7` UID connections, permits established/reply traffic only, and is installed before any target services.

SAFE-001 redirects to `OFFSCOPE_DOMAIN`, which the operator supplies as a separate registered domain. It must never be verified in Paleon and must never appear as business context. Do not invent a real domain in configuration or documentation.

Safety invariants are separate from scanner findings in `expected.yaml`. The answer key does not present unobserved scanner severity as live fact. The zone-transfer fixture remains deferred because adding another nameserver/private A record could impair DNS resolution.

# Site 7 deployment configuration (not an instruction to deploy now)

This repository is locally validated only. No Site 7 deployment is authorized by this document. Do not apply Terraform, create AWS resources, edit DNS, issue a public certificate, verify the domain in Paleon, or run a live scan as part of repository review.

When a separate deployment is approved, Site 7 must use AWS region `eu-west-2` and the same lab AWS account used by Paleon Sites 1–6. Never use the Paleon SaaS/application account. The actual account ID is not recorded here. The operator must explicitly provide the Sites 1–6 lab account ID through required `expected_aws_account_id`; Terraform validates it against `aws_caller_identity.current` before creating Site 7 resources. Inspect `current_aws_account_id` output as well. No AWS credentials are stored in the repository.

Set required variables locally, without committing secrets: `admin_ip`, `key_name`, `route53_zone_id`, `offscope_domain`, and `expected_aws_account_id`. `OFFSCOPE_DOMAIN` must be a separately registered domain, outside `paleon-lab-hostile.com`, never verified in Paleon, and never included as a business-context host. Set it through a local untracked `terraform.tfvars` entry (`offscope_domain = "<operator-owned-domain>"`) or a Terraform `-var` argument. It is used only as the redirect destination for SAFE-001. The repository intentionally does not name or register a real domain.

The centralized Terraform `hostile_subdomains` list creates DNS records and the certificate SANs for apex plus every ordinary stimulus host. It excludes `rebind-test` because alternating DNS answers can disrupt certificate validation and burn its first public answer. `ns1` is DNS infrastructure only and is also excluded from the certificate.

Bootstrap establishes and starts the persistent egress firewall before any Site 7 unit; each app, DNS, malformed-protocol, and Nginx unit requires it. Nginx preserves streamed response delivery (`proxy_buffering off`) and has finite 660 second read/stream idle timeouts. The observation path is blocked on public HTTPS and remains accessible directly through `http://127.0.0.1:5000/internal/site7-observation` on the host.

For permitted local repository checks, see the commands in [README.md](README.md). Do not use `terraform apply` during this validation task.

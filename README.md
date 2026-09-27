# Paleon Site 7: Hostile Resilience Validation Target

Site 7 is a passive target for validating scanner safety and resilience. It emits redirect headers, bounded streamed bodies, malformed protocol responses, and DNS rebinding answers. It does not follow redirects, make arbitrary third-party requests, access metadata, use IAM credentials, attack external systems, or contain real credentials or malware.

Paleon does not crawl links: it discovers a host and fetches root plus fixed paths. Each stimulus therefore has a dedicated hostname, and every path on that hostname emits the same stimulus. Flask routes by the Host header behind Nginx. The full hostname and stimulus map is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Hostnames

The ordinary certificate and host list contains `imds`, `fargate`, `rfc1918`, `loopback`, `ipv6`, `redirect-loop`, `self-loop`, `large-body`, `slow-body`, `gzip-body`, `observer`, `kill-test`, `ftp-redirect`, `slow-drip`, `slow-tls`, `malformed-http`, `malformed-tls`, and `offscope-redirect`, all under `paleon-lab-hostile.com`. `rebind-test.paleon-lab-hostile.com` is active DNS only and deliberately omitted from the certificate because its answers alternate. `ns1.paleon-lab-hostile.com` is DNS infrastructure only and is not a certificate SAN.

`OFFSCOPE_DOMAIN` is an operator-supplied, separately registered domain used only as the SAFE-001 redirect destination. Populate it with `-var='offscope_domain=your-registered-domain.example'` or in a local untracked `terraform.tfvars`. Do not verify it in Paleon and do not add it as a business-context host. No actual domain is hard-coded here.

## Deployment account and region

Site 7 is deployed only in region `eu-west-2`. The AWS account must be the same lab account used by Paleon Sites 1–6, never the Paleon SaaS/application account. The account ID is intentionally unknown; the operator must explicitly provide the Sites 1–6 lab account ID as required `expected_aws_account_id`. Terraform checks it against the active caller account before creating Site 7 resources and outputs the caller account ID for verification. No credentials or account ID belong in this repository.

## Local validation

Run `./validate.sh`, `python3 -m py_compile app/*.py test_all_endpoints.py`, and `bash -n reset.sh validate.sh verify.sh`. Terraform checks, when Terraform is available, are `terraform -chdir=terraform init -backend=false`, `terraform -chdir=terraform validate`, and `terraform -chdir=terraform fmt -check -recursive`. Public-boundary tests require an explicit deployed EIP: `python3 test_all_endpoints.py <EIP>`; they must not infer one from DNS.

The deployment guide describes configuration for a future reviewed deployment. Repository validation must not run `terraform apply`, create cloud resources, modify DNS, issue certificates, verify a domain in Paleon, or scan the live target. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), [docs/isolation.md](docs/isolation.md), and [expected.yaml](expected.yaml).

# PALEON TEST SITE 7 — Deployment Guide

This document describes how to deploy PALEON TEST SITE 7 in an isolated environment.

## Prerequisites

- AWS account with permissions to create EC2, EIP, Route53 records, and Security Groups
- Terraform >= 1.5.0
- DNS zone for `paleon-lab-hostile.com` (or use a test domain) hosted in Route 53
- SSH key pair for EC2 access (optional but recommended)
- Approximately 15-20 minutes for deployment

## Deployment Steps

### 1. Clone Repository

```bash
git clone https://github.com/miftahu1/paleon-lab-hostile.git
cd paleon-lab-hostile
```

### 2. Configure Variables

Create a `terraform.tfvars` file with your specific values:

```hcl
# Required variables
aws_region              = "us-east-1"
hostname                = "paleon-lab-hostile.com"
offscope_hostname       = "offscope.paleon-lab-hostile.com"
rebind_hostname         = "rebind-test.paleon-lab-hostile.com"
route53_zone_id         = "Z3M3LMPEXAMPLE"   # Your hosted zone ID
admin_ip                = "203.0.113.50/32"  # Your IP for SSH access
key_name                = "my-site7-key"     # Existing EC2 key pair name

# Optional variables (defaults shown)
instance_type           = "t3.micro"
ami_id                  = ""                  # empty = auto-discover latest Ubuntu 24.04 LTS
project_name            = "paleon-site7"
```

> **Note**: `route53_zone_id` and `admin_ip` are required in practice (their defaults are empty). Leave `ami_id` empty to let Terraform select the most recent Canonical Ubuntu 24.04 LTS AMI in the region; override it only to pin a specific Ubuntu 24.04 image.

### 3. Initialize Terraform

```bash
cd terraform
terraform init
```

### 4. Review Deployment Plan

```bash
terraform plan -var-file=../terraform.tfvars
```

Review the plan carefully. All resources are created with the `paleon-site7` prefix.

### 5. Apply Deployment

```bash
terraform apply -var-file=../terraform.tfvars
```

Type `yes` when prompted. The deployment will:
- Create a security group allowing HTTP/HTTPS and DNS (TCP+UDP 53) from anywhere, and SSH from your admin IP only
- Launch an EC2 instance (`t3.micro`, Ubuntu 24.04 LTS) with **no IAM role** and IMDSv2 required
- Allocate an Elastic IP and attach it via `aws_eip_association`
- Create Route 53 records: `A` for apex, `offscope`, `malformed-http`, `malformed-tls`, and `ns1` (all → EIP), plus an `NS` record delegating `rebind-test` to `ns1`
- Execute the user-data bootstrap script

### 6. Post-Deployment Verification

After approximately 5-10 minutes (for bootstrap completion), run the runtime verifier against the instance EIP:

```bash
../verify.sh <eip>
```

This script verifies, over the network:
- Hostname/SNI routing works
- Test endpoints return the correct headers / raw bytes
- Malformed HTTP and malformed TLS behave as designed (raw-byte inspection, not `curl | grep`)
- The DNS rebinding contract holds (public first, private after, TTL=0)

For an automated public-boundary check, also run:

```bash
python3 ../test_all_endpoints.py <eip>
```

### 7. Accessing the Site

Once deployed, access via:
- Primary: `https://paleon-lab-hostile.com`
- Off-scope: `https://offscope.paleon-lab-hostile.com`
- Malformed HTTP: `https://malformed-http.paleon-lab-hostile.com/malformed/{chunked,banner}`
- Malformed TLS: `https://malformed-tls.paleon-lab-hostile.com/` (handshake never completes)
- Rebind test: `rebind-test.paleon-lab-hostile.com` (DNS only, delegated to `ns1`)

> **Important**: The apex, off-scope, malformed, and `ns1` names all resolve to the same EIP. The distinction is purely for testing scope enforcement, SNI-based malformed routing, and DNS rebinding.

## Local Development / Testing

There is no container stack. For local iteration, run the services directly with Python.

```bash
# Install dependencies (single requirements file at the repo root)
pip install -r requirements.txt

# Main Flask app — binds 127.0.0.1:5000
python3 app/app.py
```

The malformed server needs a TLS certificate/key at `/etc/ssl/site7/` and the DNS server needs to bind port 53 (privileged), so both are normally exercised on the deployed instance under `systemd` rather than locally. To validate the repository statically without any host:

```bash
./validate.sh
```

## Reset Procedures

### Full Infrastructure Reset

To destroy all AWS resources:

```bash
cd terraform
terraform destroy -var-file=../terraform.tfvars
```

This removes ALL resources created by Terraform. The Elastic IP is released back to AWS.

### Service-Only Reset

To reset just the application state on the instance (keeping infrastructure):

```bash
sudo ./reset.sh
```

This stops the services, restores the DNS-rebinding state file to its initial (public-first) condition, and restarts the services. In-memory observations are discarded automatically when the Flask service restarts — there are no on-disk observation logs to clear.

## DNS Rebind Testing

The DNS rebind test is served by `site7-rebind-dns` on port 53. To manually test on the instance (or against the EIP):

1. First lookup (should return the public EIP):
   ```bash
   dig @127.0.0.1 rebind-test.paleon-lab-hostile.com A +short
   ```

2. Second lookup (should return `192.168.1.1`):
   ```bash
   dig @127.0.0.1 rebind-test.paleon-lab-hostile.com A +short
   ```

To reset the rebind state:
```bash
sudo ./reset.sh
# or, directly:
python3 app/rebind_dns_server.py reset
```

## Security Notes

### Isolation Features

1. **No IAM Role**: The EC2 instance has no attached IAM role or instance profile, and IMDSv2 is required — there are no role credentials to steal.
2. **Security Group**:
   - Ingress: HTTP/HTTPS and DNS (TCP+UDP 53) from `0.0.0.0/0`; SSH from `admin_ip` only
   - Default AWS egress is retained so bootstrap can `apt`/`git`; application egress is restricted on-host (see below)
   - No shared security groups with other sites
3. **Network**:
   - Uses the default VPC (no custom VPC, IGW, or NAT created)
   - No VPC peering, Transit Gateway, or VPN connections
4. **Host egress isolation**:
   - `iptables`/`ip6tables` `owner --uid-owner site7` rules `REJECT` traffic from the `site7` user to RFC1918, link-local (`169.254.0.0/16`), and IPv6 ULA/link-local ranges
   - Installed by `site7-egress-firewall.service`, a `systemd` oneshot ordered before networking, so it **persists across reboot**
5. **Application**:
   - No outbound network calls from any service
   - Flask, the Nginx termination, and the malformed backends bind `127.0.0.1` only
   - No credentials, secrets, tokens, or database

### What Site 7 Does NOT Do

- ✅ No outbound calls to metadata services (`169.254.169.254`, `169.254.170.2`) — these appear only as redirect `Location` bait
- ✅ No proxying or relaying of requests
- ✅ No credential harvesting or storage
- ✅ No execution of arbitrary code
- ✅ No persistent storage of scan data (observations are in-memory only)
- ✅ No network scanning or port scanning

## Troubleshooting

### Services Not Starting

Check logs:
```bash
journalctl -u paleon-site7 -f
journalctl -u site7-malformed-server -f
journalctl -u site7-rebind-dns -f
journalctl -u site7-egress-firewall
```

### DNS Not Resolving

1. Verify Route53 records:
   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id Z3M3LMPEXAMPLE
   ```

2. Check resolution (rebind-test is delegated via NS to ns1):
   ```bash
   dig paleon-lab-hostile.com
   dig offscope.paleon-lab-hostile.com
   dig NS rebind-test.paleon-lab-hostile.com
   ```

### Application Errors

Check application logs:
```bash
journalctl -u paleon-site7
```

### Verification Fails

Run static validation first:
```bash
../validate.sh
```

This checks for missing files, syntax errors, stale configuration strings, and architectural drift before runtime verification.

## Cost Estimates

### Monthly AWS Costs (us-east-1)

- `t3.micro` EC2: ~$8.50
- Elastic IP: free while attached to a running instance (charged only when idle/unattached)
- Route53 hosted zone: $0.50/month + $0.40 per million queries
- Data transfer: variable based on usage

**Total**: Approximately $10-15/month for light test usage

### Cost Optimization

1. **Stop when not in use**:
   ```bash
   aws ec2 stop-instances --instance-ids i-xxxxxxxxxxxxxxxxx
   aws ec2 start-instances --instance-ids i-xxxxxxxxxxxxxxxxx
   ```
   (Note: a stopped instance still incurs the idle-EIP charge.)

2. **Destroy when finished**:
   ```bash
   terraform destroy -var-file=../terraform.tfvars
   ```

## Important Reminders

> ⚠️ **THIS TARGET IS DESIGNED TO ATTEMPT TO INDUCE THE SCANNER TO LEAVE ITS TRUST BOUNDARY.**
>
> - Do not deploy in any VPC with connectivity to production infrastructure
> - Do not use production AWS accounts or credentials
> - Do not scan with production scanners without proper isolation
> - This target is for VALIDATION ONLY — not for production use
> - Always verify isolation before scanning
> - The reset script is safe to run repeatedly
> - Terraform state contains no secrets — only resource IDs and configuration

## References

- [README.md](./README.md) — Overview and test matrix
- [ARCHITECTURE.md](./ARCHITECTURE.md) — Detailed architecture
- [expected.yaml](./expected.yaml) — Resilience test definitions
- [docs/](./docs/) — Detailed threat model and test specifications

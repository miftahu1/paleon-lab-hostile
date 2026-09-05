# ==============================================================================
# PALEON TEST SITE 7 - Backend Configuration
# ==============================================================================
# Local backend for Site 7 isolated lab.
# No S3 backend -- this is an isolated test target.
# State is stored locally in terraform.tfstate.
#
# WARNING: Do NOT migrate to a remote backend. This site is intentionally
# isolated from other Paleon test sites. Local state means single-operator
# usage only; do not share this directory across machines.
# ==============================================================================

terraform {
  backend "local" {
    # State file will be written to ./terraform.tfstate in this directory.
    # No encryption-at-rest for local state; protect the directory if the
    # host is shared.
  }
}

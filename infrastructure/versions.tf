# Terraform and provider version constraints.
#
# Provider versions are pinned to match the reference implementation in
# /workshop/option1 (see its .terraform.lock.hcl):
#   - hashicorp/aws     6.69.1
#   - hashicorp/archive 2.8.1  (Lambda deployment packaging)
#   - hashicorp/null    3.3.2  (build/local-exec packaging steps)
terraform {
  required_version = ">= 1.10.0"

  # Remote state in S3. The bucket and per-stage key are supplied at init via
  # -backend-config (see the CI workflow), so dev and prod use distinct state
  # keys in the same bucket. use_lockfile uses S3-native locking (no DynamoDB).
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }
  }
}

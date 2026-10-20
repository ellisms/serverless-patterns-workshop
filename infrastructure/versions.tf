# Terraform and provider version constraints.
#
# Provider versions are pinned to match the reference implementation in
# /workshop/option1 (see its .terraform.lock.hcl):
#   - hashicorp/aws     6.69.1
#   - hashicorp/archive 2.8.1  (Lambda deployment packaging)
#   - hashicorp/null    3.3.2  (build/local-exec packaging steps)
terraform {
  required_version = ">= 1.0.0"

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

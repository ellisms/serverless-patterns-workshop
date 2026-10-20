# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# --------------------------------------------------------------------------- #
# Remote Terraform state bucket (S3).
#
# Replaces the fragile artifact-based local state with a durable, versioned,
# encrypted S3 backend. Each stage uses a distinct state key
# (workshop-dev/terraform.tfstate, workshop-prod/terraform.tfstate) passed via
# -backend-config at init time, so dev and prod never share state. State locking
# uses S3 native lockfiles (Terraform >= 1.9 use_lockfile) -- no DynamoDB table
# needed.
#
# The bucket name must be globally unique; it is suffixed with the account id.
# No prevent_destroy (workshop teardown), but versioning is on so state history
# is recoverable.
# --------------------------------------------------------------------------- #
variable "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state. Defaults to a per-account unique name."
  type        = string
  default     = null
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket = coalesce(var.state_bucket_name, "${var.role_name}-tfstate-${data.aws_caller_identity.current.account_id}")
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket

  tags = {
    Project = "CustomerManagementPlatform"
    Purpose = "terraform-remote-state"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket_name" {
  description = "S3 bucket for Terraform remote state (use as backend bucket)."
  value       = aws_s3_bucket.tfstate.id
}

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# One-time bootstrap: GitHub Actions OIDC provider + deploy IAM role.
# Keeps its OWN local state in this directory, separate from the main stack.
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "github_owner" {
  description = "GitHub repository owner/org that is allowed to assume the deploy role."
  type        = string
  default     = "ellisms"
}

variable "github_repo" {
  description = "GitHub repository name allowed to assume the deploy role."
  type        = string
  default     = "serverless-patterns-workshop"
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes via OIDC."
  type        = string
  default     = "workshop-github-actions-deploy"
}

variable "create_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false if one already exists in the account."
  type        = bool
  default     = true
}

# Broad by default for the workshop. The pipeline deploys Lambda, IAM, API
# Gateway, DynamoDB, Cognito, CloudWatch (logs/alarms/dashboard), X-Ray, and the
# API Gateway account setting -- AdministratorAccess covers all of these.
# TIGHTEN THIS to a least-privilege policy for anything beyond a workshop.
variable "deploy_policy_arn" {
  description = "Managed policy ARN attached to the deploy role."
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}

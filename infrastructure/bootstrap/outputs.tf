# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "deploy_role_arn" {
  description = "ARN of the role GitHub Actions assumes. Set as repo variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.github_actions_deploy.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider in use."
  value       = local.oidc_provider_arn
}

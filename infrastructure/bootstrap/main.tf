# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# --------------------------------------------------------------------------- #
# GitHub Actions OIDC provider.
#
# Either created here (create_oidc_provider = true) or looked up if it already
# exists in the account. A local selects whichever ARN is in play.
# --------------------------------------------------------------------------- #
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's OIDC thumbprint. AWS no longer strictly validates this for the
  # GitHub provider, but the argument is still required.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# --------------------------------------------------------------------------- #
# Deploy role GitHub Actions assumes via OIDC.
#
# Trust is scoped to this repo (any branch/PR), since dev deploys on all
# pushes/PRs. Prod is gated separately by a protected GitHub Environment with a
# required reviewer -- not by the trust policy.
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Project = "CustomerManagementPlatform"
    Purpose = "github-actions-oidc-deploy"
  }
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = var.deploy_policy_arn
}

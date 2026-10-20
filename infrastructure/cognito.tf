#######################################################################
# Cognito User Pool, app client, hosted-UI domain, and admin group for
# the Customer Management Platform.
#
# The user pool issues the JWTs that the Lambda Authorizer validates. The
# app client is a public client (no secret) with explicit auth flows that
# let integration tests obtain id/access tokens via username+password, so
# the authorizer can validate aud/client_id == APPLICATION_CLIENT_ID.
#
# Region is never hardcoded; data sources resolve it from the active
# AWS profile / AWS_REGION. No prevent_destroy / deletion protection.
#######################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --------------------------------------------------------------------- #
# User pool.
# --------------------------------------------------------------------- #
resource "aws_cognito_user_pool" "pool" {
  name = var.user_pool_name

  # Use email as the sign-in alias/username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Require email as a standard attribute.
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }

  # Password policy: >= 8 chars, requiring numbers, symbols, upper & lower.
  password_policy {
    minimum_length    = 8
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
    require_lowercase = true
  }

  # Self-registration with email verification.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your verification code"
    email_message        = "Your verification code is {####}"
  }

  # Account recovery via verified email.
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Advanced security in audit-only mode.
  user_pool_add_ons {
    advanced_security_mode = "AUDIT"
  }

  tags = {
    Name        = var.user_pool_name
    Environment = var.environment
    Project     = var.project
  }
}

# --------------------------------------------------------------------- #
# User pool client.
#
# generate_secret = false so integration tests can obtain tokens without a
# client secret. Explicit auth flows allow username+password and admin
# username+password auth (plus refresh), which is enough to mint id/access
# tokens the authorizer accepts.
# --------------------------------------------------------------------- #
resource "aws_cognito_user_pool_client" "client" {
  name         = var.app_client_name
  user_pool_id = aws_cognito_user_pool.pool.id

  # Public client (no secret) suitable for localhost / SPA development and
  # for integration tests that authenticate with username + password.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Token validity. Refresh token = 30 days.
  refresh_token_validity = 30
  access_token_validity  = 60
  id_token_validity      = 60
  token_validity_units {
    refresh_token = "days"
    access_token  = "minutes"
    id_token      = "minutes"
  }

  # Hosted UI / OAuth settings.
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid"]
  callback_urls                        = ["http://localhost"]
  supported_identity_providers         = ["COGNITO"]

  prevent_user_existence_errors = "ENABLED"
}

# --------------------------------------------------------------------- #
# Hosted UI domain. The prefix must be globally unique within the Region,
# so it is suffixed with the account ID.
# --------------------------------------------------------------------- #
resource "aws_cognito_user_pool_domain" "domain" {
  domain       = "${var.workshop_stack_base_name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.pool.id
}

# --------------------------------------------------------------------- #
# Admin group. Membership is surfaced to the authorizer as the isAdmin
# context value; the authorizer checks ADMIN_GROUP_NAME == this name.
# --------------------------------------------------------------------- #
resource "aws_cognito_user_group" "administrators" {
  name         = var.admin_group_name
  user_pool_id = aws_cognito_user_pool.pool.id
  description  = "Administrative users for the ${var.project} project."
  precedence   = 1
}

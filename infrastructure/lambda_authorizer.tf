#######################################################################
# Build / packaging for the Lambda Authorizer deployment artifact.
#
# The authorizer handler (src/authorizer/lambda_authorizer.py) depends on
# PyJWT[crypto], which ships compiled extensions. Dependencies are therefore
# installed with pip targeting the Lambda runtime (manylinux2014_x86_64,
# Python 3.13, x86_64) into a build/ folder under this module, together with
# the handler source. The build/ folder is then zipped. src/ is NEVER modified.
#
# This file is ONLY the packaging plumbing (null_resource + archive_file). The
# aws_lambda_function, its IAM role, and environment variables are declared in
# task 12.2. The archive outputs below are exposed so 12.2 can consume them.
#######################################################################

locals {
  authorizer_src_dir   = "${path.module}/../src/authorizer"
  authorizer_build_dir = "${path.module}/build/authorizer"
  authorizer_zip_path  = "${path.module}/build/authorizer.zip"
}

# --------------------------------------------------------------------- #
# Build: install deps compiled for the Lambda runtime, then copy the
# handler. Re-runs whenever the source or requirements change (the triggers
# hash the requirements.txt and handler so edits force a rebuild).
# --------------------------------------------------------------------- #
resource "null_resource" "authorizer_build" {
  triggers = {
    requirements = filemd5("${local.authorizer_src_dir}/requirements.txt")
    handler      = filemd5("${local.authorizer_src_dir}/lambda_authorizer.py")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf "${local.authorizer_build_dir}"
      mkdir -p "${local.authorizer_build_dir}"

      # Install dependencies (PyJWT[crypto]==2.8.0) compiled for the Lambda
      # runtime rather than this host: x86_64, Python 3.13, wheels only.
      python3.13 -m pip install \
        --requirement "${local.authorizer_src_dir}/requirements.txt" \
        --target "${local.authorizer_build_dir}" \
        --platform manylinux2014_x86_64 \
        --python-version 3.13 \
        --implementation cp \
        --only-binary=:all: \
        --upgrade

      # Copy the handler source (never modifying src/).
      cp "${local.authorizer_src_dir}/lambda_authorizer.py" "${local.authorizer_build_dir}/"
    EOT
  }
}

# --------------------------------------------------------------------- #
# Package the build folder as a ZIP once the build has completed.
# --------------------------------------------------------------------- #
data "archive_file" "authorizer_zip" {
  type        = "zip"
  source_dir  = local.authorizer_build_dir
  output_path = local.authorizer_zip_path

  depends_on = [null_resource.authorizer_build]
}

# --------------------------------------------------------------------- #
# Packaging outputs consumed by task 12.2 (aws_lambda_function).
# --------------------------------------------------------------------- #
output "authorizer_zip_path" {
  description = "Path to the zipped authorizer deployment package."
  value       = data.archive_file.authorizer_zip.output_path
}

output "authorizer_source_code_hash" {
  description = "Base64 SHA-256 of the authorizer deployment package (triggers Lambda updates)."
  value       = data.archive_file.authorizer_zip.output_base64sha256
}

#######################################################################
# Task 12.2 - Lambda Authorizer function, IAM role, and environment vars.
#
# The authorizer validates Cognito JWTs and makes NO AWS API calls, so its
# role carries only the AWSLambdaBasicExecutionRole managed policy (CloudWatch
# Logs) and NO DynamoDB access. API Gateway wiring (aws_lambda_permission and
# aws_api_gateway_authorizer) belongs to task 13 and is intentionally omitted
# here. CloudWatch log groups are task 14; the basic-execution role is enough
# for the function to write logs.
#
# runtime python3.13 / x86_64. Timeout is kept at the 5s ceiling the design
# calls for so that an unreachable identity provider surfaces as a failed
# authorization within the window rather than hanging.
#######################################################################

locals {
  authorizer_function_name = "${var.workshop_stack_base_name}-authorizer-function"
}

# --------------------------------------------------------------------- #
# IAM: trust policy (lambda.amazonaws.com) + CloudWatch Logs only.
# --------------------------------------------------------------------- #
data "aws_iam_policy_document" "authorizer_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "authorizer_lambda_role" {
  name               = "${local.authorizer_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.authorizer_assume_role.json

  tags = {
    Name        = "${local.authorizer_function_name}-role"
    Environment = var.environment
    Project     = var.project
  }
}

# CloudWatch Logs permissions for the function (no DynamoDB access).
resource "aws_iam_role_policy_attachment" "authorizer_basic_execution" {
  role       = aws_iam_role.authorizer_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------- #
# Authorizer Lambda function.
# --------------------------------------------------------------------- #
resource "aws_lambda_function" "authorizer" {
  function_name = local.authorizer_function_name
  role          = aws_iam_role.authorizer_lambda_role.arn
  handler       = "lambda_authorizer.lambda_handler"
  runtime       = "python3.13"
  architectures = ["x86_64"]

  filename         = data.archive_file.authorizer_zip.output_path
  source_code_hash = data.archive_file.authorizer_zip.output_base64sha256

  memory_size = 256

  # 5s ceiling: an unavailable IdP / JWKS endpoint must surface as a failed
  # authorization within the window rather than hanging the request.
  timeout = 5

  environment {
    variables = {
      USER_POOL_ID          = aws_cognito_user_pool.pool.id
      APPLICATION_CLIENT_ID = aws_cognito_user_pool_client.client.id
      ADMIN_GROUP_NAME      = aws_cognito_user_group.administrators.name
    }
  }

  # Active X-Ray tracing: every invocation records an X-Ray segment, and the
  # execution role is granted X-Ray write permissions in observability.tf.
  tracing_config {
    mode = "Active"
  }

  tags = {
    Name        = local.authorizer_function_name
    Environment = var.environment
    Project     = var.project
  }

  # Depend on the managed log group so this function's logs land in the
  # retention-managed group rather than one Lambda auto-creates first.
  depends_on = [
    aws_iam_role_policy_attachment.authorizer_basic_execution,
    aws_cloudwatch_log_group.authorizer,
  ]
}

# --------------------------------------------------------------------- #
# Outputs consumed by task 13 (API Gateway authorizer wiring).
# --------------------------------------------------------------------- #
output "authorizer_lambda_arn" {
  description = "ARN of the Lambda authorizer function."
  value       = aws_lambda_function.authorizer.arn
}

output "authorizer_lambda_function_name" {
  description = "Name of the Lambda authorizer function."
  value       = aws_lambda_function.authorizer.function_name
}

output "authorizer_lambda_invoke_arn" {
  description = "Invoke ARN of the Lambda authorizer function (used by API Gateway)."
  value       = aws_lambda_function.authorizer.invoke_arn
}

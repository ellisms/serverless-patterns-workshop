#######################################################################
# Build / packaging for the users Lambda deployment artifact.
#
# The users handler (src/users/app.py) relies only on the Python standard
# library plus boto3, which the Lambda runtime already provides, so
# requirements.txt usually installs nothing. We still run pip against it (so
# any future dependency is bundled automatically) targeting the Lambda runtime
# (manylinux2014_x86_64, Python 3.13, x86_64) into a build/ folder under this
# module, then copy the handler source and zip the build/ folder. src/ is
# NEVER modified.
#
# This file is ONLY the packaging plumbing (null_resource + archive_file). The
# aws_lambda_function, its IAM role, and environment variables are declared in
# task 12.2. The archive outputs below are exposed so 12.2 can consume them.
#######################################################################

locals {
  users_src_dir   = "${path.module}/../src/users"
  users_build_dir = "${path.module}/build/users"
  users_zip_path  = "${path.module}/build/users.zip"
}

# --------------------------------------------------------------------- #
# Build: install any requirements for the Lambda runtime, then copy the
# handler. Re-runs whenever the source or requirements change.
# --------------------------------------------------------------------- #
resource "null_resource" "users_build" {
  triggers = {
    requirements = filemd5("${local.users_src_dir}/requirements.txt")
    handler      = filemd5("${local.users_src_dir}/app.py")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf "${local.users_build_dir}"
      mkdir -p "${local.users_build_dir}"

      # Install dependencies compiled for the Lambda runtime rather than this
      # host: x86_64, Python 3.13, wheels only. requirements.txt currently has
      # no third-party deps (boto3 is provided by the runtime), so this is a
      # no-op today but keeps future deps bundled automatically. --no-deps-ish
      # behavior is unnecessary; an empty file simply installs nothing.
      if grep -qvE '^\s*(#.*)?$' "${local.users_src_dir}/requirements.txt"; then
        python3.13 -m pip install \
          --requirement "${local.users_src_dir}/requirements.txt" \
          --target "${local.users_build_dir}" \
          --platform manylinux2014_x86_64 \
          --python-version 3.13 \
          --implementation cp \
          --only-binary=:all: \
          --upgrade
      fi

      # Copy the handler source (never modifying src/).
      cp "${local.users_src_dir}/app.py" "${local.users_build_dir}/"
    EOT
  }
}

# --------------------------------------------------------------------- #
# Package the build folder as a ZIP once the build has completed.
# --------------------------------------------------------------------- #
data "archive_file" "users_zip" {
  type        = "zip"
  source_dir  = local.users_build_dir
  output_path = local.users_zip_path

  depends_on = [null_resource.users_build]
}

# --------------------------------------------------------------------- #
# Packaging outputs consumed by task 12.2 (aws_lambda_function).
# --------------------------------------------------------------------- #
output "users_zip_path" {
  description = "Path to the zipped users deployment package."
  value       = data.archive_file.users_zip.output_path
}

output "users_source_code_hash" {
  description = "Base64 SHA-256 of the users deployment package (triggers Lambda updates)."
  value       = data.archive_file.users_zip.output_base64sha256
}

#######################################################################
# Task 12.2 - Users Lambda function, least-privilege IAM role, env vars.
#
# runtime python3.13 / x86_64. The function needs CloudWatch Logs plus a
# tightly scoped DynamoDB policy. Per requirement R7 (least privilege), the
# DynamoDB statement is scoped to ONLY the customers table ARN and its
# email-index GSI ARN -- no wildcards, no other tables, no other indexes.
#
# API Gateway wiring (aws_lambda_permission, AWS_PROXY integration) belongs to
# task 13 and is intentionally omitted here. CloudWatch log groups are task 14.
#######################################################################

locals {
  users_function_name = "${var.workshop_stack_base_name}-users-function"
}

# --------------------------------------------------------------------- #
# IAM: trust policy (lambda.amazonaws.com) + CloudWatch Logs + scoped DDB.
# --------------------------------------------------------------------- #
data "aws_iam_policy_document" "users_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "users_lambda_role" {
  name               = "${local.users_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.users_assume_role.json

  tags = {
    Name        = "${local.users_function_name}-role"
    Environment = var.environment
    Project     = var.project
  }
}

# CloudWatch Logs permissions for the function.
resource "aws_iam_role_policy_attachment" "users_basic_execution" {
  role       = aws_iam_role.users_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB access, least privilege: ONLY the customers table and its
# email-index GSI. The handler performs single-item reads/writes, Scans for
# listing, Query against the email-index, and TransactWriteItems for the
# email-uniqueness guard-item mechanism.
data "aws_iam_policy_document" "users_dynamodb" {
  statement {
    sid    = "CustomersTableCrud"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Scan",
      "dynamodb:Query",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:TransactWriteItems",
    ]
    resources = [
      aws_dynamodb_table.customers_table.arn,
      "${aws_dynamodb_table.customers_table.arn}/index/email-index",
    ]
  }
}

resource "aws_iam_role_policy" "users_dynamodb" {
  name   = "${local.users_function_name}-dynamodb"
  role   = aws_iam_role.users_lambda_role.id
  policy = data.aws_iam_policy_document.users_dynamodb.json
}

# --------------------------------------------------------------------- #
# Users Lambda function.
# --------------------------------------------------------------------- #
resource "aws_lambda_function" "users" {
  function_name = local.users_function_name
  role          = aws_iam_role.users_lambda_role.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.13"
  architectures = ["x86_64"]

  filename         = data.archive_file.users_zip.output_path
  source_code_hash = data.archive_file.users_zip.output_base64sha256

  memory_size = 256
  timeout     = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.customers_table.name
    }
  }

  # Active X-Ray tracing: every invocation records an X-Ray segment, and the
  # execution role is granted X-Ray write permissions in observability.tf.
  tracing_config {
    mode = "Active"
  }

  tags = {
    Name        = local.users_function_name
    Environment = var.environment
    Project     = var.project
  }

  # Depend on the managed log group so this function's logs land in the
  # retention-managed group rather than one Lambda auto-creates first.
  depends_on = [
    aws_iam_role_policy_attachment.users_basic_execution,
    aws_iam_role_policy.users_dynamodb,
    aws_cloudwatch_log_group.users,
  ]
}

# --------------------------------------------------------------------- #
# Outputs consumed by task 13 (API Gateway integration).
# --------------------------------------------------------------------- #
output "users_lambda_arn" {
  description = "ARN of the users Lambda function."
  value       = aws_lambda_function.users.arn
}

output "users_lambda_function_name" {
  description = "Name of the users Lambda function."
  value       = aws_lambda_function.users.function_name
}

output "users_lambda_invoke_arn" {
  description = "Invoke ARN of the users Lambda function (used by API Gateway)."
  value       = aws_lambda_function.users.invoke_arn
}

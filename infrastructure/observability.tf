#######################################################################
# Observability add-ons for the Customer Management Platform.
#
# This file owns the cross-cutting observability resources that are added on
# top of the base stack. For this task it grants the two Lambda execution
# roles the AWS X-Ray write permissions that Active tracing requires.
#
# Both aws_lambda_function.users and aws_lambda_function.authorizer now run
# with tracing_config.mode = "Active" (see users-lambda.tf and
# lambda_authorizer.tf). Active tracing only records segments if the function
# role can write to X-Ray, so each role gets the AWS managed policy
# AWSXRayDaemonWriteAccess attached alongside its existing
# AWSLambdaBasicExecutionRole attachment. The roles' current posture is
# otherwise unchanged.
#
# Region is never hardcoded; no prevent_destroy / deletion protection
# (workshop teardown with terraform destroy).
#######################################################################

# --------------------------------------------------------------------- #
# X-Ray write permissions for the Lambda execution roles.
#
# AWSXRayDaemonWriteAccess is exactly the write set Lambda needs to record
# traces (xray:PutTraceSegments, xray:PutTelemetryRecords, plus sampling
# reads) -- least privilege, attached next to the existing basic-execution
# policy so logging access is preserved and only trace permissions are added.
# --------------------------------------------------------------------- #
resource "aws_iam_role_policy_attachment" "users_xray" {
  role       = aws_iam_role.users_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "authorizer_xray" {
  role       = aws_iam_role.authorizer_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# --------------------------------------------------------------------- #
# API Gateway account-level CloudWatch Logs role (task 2.1).
#
# API Gateway cannot write ANY stage logs (execution or access) until the
# account's CloudWatch Logs role ARN is set. This is a one-time, account-wide
# (per region) prerequisite -- a common first-deploy failure if omitted. The
# Prod stage's access/execution logging (task 2.2) depends_on this account
# setting so the role exists before logging is enabled.
#
# Region is never hardcoded; no prevent_destroy (workshop teardown).
# --------------------------------------------------------------------- #
data "aws_iam_policy_document" "apigw_cloudwatch_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  name               = "${var.workshop_stack_base_name}-apigw-cloudwatch-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_cloudwatch_assume_role.json

  tags = {
    Name        = "${var.workshop_stack_base_name}-apigw-cloudwatch-role"
    Environment = var.environment
    Project     = var.project
  }
}

# The AWS managed policy that lets API Gateway push execution/access logs to
# CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# Account-wide API Gateway setting (one per account/region). Points API Gateway
# at the role above so stages are permitted to write logs.
resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn

  depends_on = [aws_iam_role_policy_attachment.apigw_cloudwatch]
}

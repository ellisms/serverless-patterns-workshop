#######################################################################
# Observability for the Customer Management Platform Lambdas.
#
# Declares the canonical CloudWatch log group for each Lambda function
# (users + authorizer) with retention driven by var.log_retention_in_days,
# plus basic Errors / Throttles metric alarms per function mirroring the
# reference implementation in /workshop/option1.
#
# Task 12.2 did NOT create explicit log groups (the functions rely on the
# AWSLambdaBasicExecutionRole to write logs). These are therefore the
# authoritative log groups. Lambda auto-creates "/aws/lambda/<fn>" on first
# invocation, so the functions depend on these groups to avoid a race where
# Lambda creates an unmanaged group first.
#
# Region is never hardcoded; it comes from the active AWS profile / AWS_REGION
# (data.aws_region.current is declared in cognito.tf and reused if needed).
# No prevent_destroy / deletion protection (workshop teardown).
#######################################################################

# --------------------------------------------------------------------- #
# CloudWatch log groups. Names match the convention Lambda uses so these
# managed groups own the functions' logs, with retention from the variable.
# --------------------------------------------------------------------- #
resource "aws_cloudwatch_log_group" "users" {
  name              = "/aws/lambda/${local.users_function_name}"
  retention_in_days = var.log_retention_in_days

  tags = {
    Name        = "/aws/lambda/${local.users_function_name}"
    Environment = var.environment
    Project     = var.project
  }
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${local.authorizer_function_name}"
  retention_in_days = var.log_retention_in_days

  tags = {
    Name        = "/aws/lambda/${local.authorizer_function_name}"
    Environment = var.environment
    Project     = var.project
  }
}

# --------------------------------------------------------------------- #
# Users Lambda alarms: Errors and Throttles.
# namespace AWS/Lambda, dimension FunctionName, Sum over a 60s period,
# fire when >= 1 occurrence. No alarm_actions for the workshop.
# --------------------------------------------------------------------- #
resource "aws_cloudwatch_metric_alarm" "users_errors" {
  alarm_name          = "${aws_lambda_function.users.function_name}-errors"
  alarm_description   = "Users Lambda is reporting errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.users.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Name        = "${aws_lambda_function.users.function_name}-errors"
    Environment = var.environment
    Project     = var.project
  }
}

resource "aws_cloudwatch_metric_alarm" "users_throttles" {
  alarm_name          = "${aws_lambda_function.users.function_name}-throttles"
  alarm_description   = "Users Lambda invocations are being throttled."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.users.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Name        = "${aws_lambda_function.users.function_name}-throttles"
    Environment = var.environment
    Project     = var.project
  }
}

# --------------------------------------------------------------------- #
# Users Lambda custom search-latency alarm.
# Custom metric SearchLatencyMs (namespace CustomerManagementPlatform/Search,
# dimension Operation=Search) emitted by the users Lambda via EMF. Average
# over a 60s period, fires when latency >= var.search_latency_alarm_threshold_ms.
# No alarm_actions for the workshop.
# --------------------------------------------------------------------- #
resource "aws_cloudwatch_metric_alarm" "search_latency" {
  alarm_name          = "${aws_lambda_function.users.function_name}-search-latency"
  alarm_description   = "Customer search latency is elevated."
  namespace           = "CustomerManagementPlatform/Search"
  metric_name         = "SearchLatencyMs"
  dimensions          = { Operation = "Search" }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.search_latency_alarm_threshold_ms
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Name        = "${aws_lambda_function.users.function_name}-search-latency"
    Environment = var.environment
    Project     = var.project
  }
}

# --------------------------------------------------------------------- #
# Authorizer Lambda alarms: Errors and Throttles.
# --------------------------------------------------------------------- #
resource "aws_cloudwatch_metric_alarm" "authorizer_errors" {
  alarm_name          = "${aws_lambda_function.authorizer.function_name}-errors"
  alarm_description   = "Authorizer Lambda is reporting errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.authorizer.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Name        = "${aws_lambda_function.authorizer.function_name}-errors"
    Environment = var.environment
    Project     = var.project
  }
}

resource "aws_cloudwatch_metric_alarm" "authorizer_throttles" {
  alarm_name          = "${aws_lambda_function.authorizer.function_name}-throttles"
  alarm_description   = "Authorizer Lambda invocations are being throttled."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.authorizer.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Name        = "${aws_lambda_function.authorizer.function_name}-throttles"
    Environment = var.environment
    Project     = var.project
  }
}

# --------------------------------------------------------------------- #
# Outputs: log group names for reference.
# --------------------------------------------------------------------- #
output "users_log_group_name" {
  description = "CloudWatch log group name for the users Lambda."
  value       = aws_cloudwatch_log_group.users.name
}

output "authorizer_log_group_name" {
  description = "CloudWatch log group name for the authorizer Lambda."
  value       = aws_cloudwatch_log_group.authorizer.name
}

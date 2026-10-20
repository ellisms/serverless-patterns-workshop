#######################################################################
# CloudWatch dashboard for the Customer Management Platform (task 5).
#
# One dashboard visualizing the health of every Observable_Resource:
#   - Lambda (Users + Authorizer): Invocations, Errors, Throttles, Duration
#   - API Gateway (Prod stage): Count, 4XXError, 5XXError, Latency
#   - DynamoDB (Customer_Store): consumed read/write capacity + throttles
#   - Custom search metric: SearchLatencyMs (CustomerManagementPlatform/Search)
#
# Region is resolved from data.aws_region.current (declared in cognito.tf),
# never hardcoded (R5.6). No prevent_destroy / deletion protection (R5.7).
#######################################################################

locals {
  dashboard_region = data.aws_region.current.region
}

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${var.workshop_stack_base_name}-observability"

  dashboard_body = jsonencode({
    widgets = [
      # ----- Lambda: Users -----
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Users Lambda"
          region = local.dashboard_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.users_function_name],
            ["AWS/Lambda", "Errors", "FunctionName", local.users_function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", local.users_function_name],
            ["AWS/Lambda", "Duration", "FunctionName", local.users_function_name, { stat = "Average" }]
          ]
        }
      },
      # ----- Lambda: Authorizer -----
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Authorizer Lambda"
          region = local.dashboard_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.authorizer_function_name],
            ["AWS/Lambda", "Errors", "FunctionName", local.authorizer_function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", local.authorizer_function_name],
            ["AWS/Lambda", "Duration", "FunctionName", local.authorizer_function_name, { stat = "Average" }]
          ]
        }
      },
      # ----- API Gateway (Prod) -----
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway (Prod)"
          region = local.dashboard_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", local.api_name, "Stage", local.stage_name],
            ["AWS/ApiGateway", "4XXError", "ApiName", local.api_name, "Stage", local.stage_name],
            ["AWS/ApiGateway", "5XXError", "ApiName", local.api_name, "Stage", local.stage_name],
            ["AWS/ApiGateway", "Latency", "ApiName", local.api_name, "Stage", local.stage_name, { stat = "Average" }]
          ]
        }
      },
      # ----- DynamoDB (Customer_Store) -----
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB Customer_Store"
          region = local.dashboard_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", aws_dynamodb_table.customers_table.name],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.customers_table.name],
            ["AWS/DynamoDB", "ReadThrottleEvents", "TableName", aws_dynamodb_table.customers_table.name],
            ["AWS/DynamoDB", "WriteThrottleEvents", "TableName", aws_dynamodb_table.customers_table.name]
          ]
        }
      },
      # ----- Custom: search latency -----
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Customer Search Latency (SearchLatencyMs)"
          region = local.dashboard_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["CustomerManagementPlatform/Search", "SearchLatencyMs", "Operation", "Search", { stat = "Average" }],
            ["CustomerManagementPlatform/Search", "SearchLatencyMs", "Operation", "Search", { stat = "p99" }]
          ]
        }
      }
    ]
  })
}

output "dashboard_name" {
  description = "Name of the CloudWatch observability dashboard."
  value       = aws_cloudwatch_dashboard.platform.dashboard_name
}

#######################################################################
# Regional REST API Gateway for the Customer Management Platform.
#
# Resources:
#   /customers          -> GET (list), POST (create), OPTIONS (CORS)
#   /customers/{id}     -> GET, PUT, DELETE, OPTIONS (CORS)
#   /customers/search   -> GET (search), OPTIONS (CORS)
#
# Every business method uses authorization = "CUSTOM" bound to the Lambda
# Authorizer (a TOKEN authorizer keyed on the Authorization header) and an
# AWS_PROXY integration to the users Lambda. OPTIONS methods use a MOCK
# integration with authorization = "NONE" to answer CORS preflight.
#
# This file also owns the API Gateway TOKEN authorizer and the two
# aws_lambda_permission resources (users + authorizer), which task 12.x
# intentionally deferred to this task. Region is never hardcoded: it is read
# from data.aws_region.current (declared in cognito.tf) for the invoke URL.
#######################################################################

locals {
  api_name         = "${var.workshop_stack_base_name}-api"
  cors_origin      = "*"
  cors_headers     = "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token"
  cors_methods     = "GET,POST,PUT,DELETE,OPTIONS"
  stage_name       = "Prod"
  users_invoke_arn = aws_lambda_function.users.invoke_arn
}

resource "aws_api_gateway_rest_api" "api" {
  name        = local.api_name
  description = "Customer Management Platform REST API for the ${var.project} project."

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name        = local.api_name
    Environment = var.environment
    Project     = var.project
  }
}

# --------------------------------------------------------------------- #
# API Gateway TOKEN authorizer, keyed on the Authorization header.
#
# Deferred here from task 12.x. The authorizer Lambda is declared in
# lambda_authorizer.tf; API Gateway invokes it via its invoke ARN and the
# aws_lambda_permission below grants that invoke.
# --------------------------------------------------------------------- #
resource "aws_api_gateway_authorizer" "cognito_jwt" {
  name                             = "${var.workshop_stack_base_name}-token-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.api.id
  type                             = "TOKEN"
  identity_source                  = "method.request.header.Authorization"
  authorizer_uri                   = aws_lambda_function.authorizer.invoke_arn
  authorizer_result_ttl_in_seconds = 300
}

# --------------------------------------------------------------------- #
# Resources: /customers and /customers/{id}
# --------------------------------------------------------------------- #
resource "aws_api_gateway_resource" "customers" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "customers"
}

resource "aws_api_gateway_resource" "customer_id" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.customers.id
  path_part   = "{id}"
}

# /customers/search -> GET (search), OPTIONS (CORS). The literal "search"
# path part sits alongside "{id}" under /customers; API Gateway matches the
# literal segment ahead of the greedy {id} parameter, so GET /customers/search
# never collides with GET /customers/{id}.
resource "aws_api_gateway_resource" "customer_search" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.customers.id
  path_part   = "search"
}

# --------------------------------------------------------------------- #
# Lambda proxy integrations.
#
# AWS_PROXY passes the whole request to Lambda and returns its response
# verbatim, so no per-method request/response mapping templates are needed
# on the integration itself; the function shapes the response.
# --------------------------------------------------------------------- #

# ---- GET /customers (list) ----
resource "aws_api_gateway_method" "customers_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customers.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.cognito_jwt.id
  request_parameters = {
    "method.request.querystring.limit"  = false
    "method.request.querystring.cursor" = false
  }
}

resource "aws_api_gateway_integration" "customers_get" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.customers.id
  http_method             = aws_api_gateway_method.customers_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.users_invoke_arn
}

# ---- POST /customers (create) ----
resource "aws_api_gateway_method" "customers_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customers.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.cognito_jwt.id
}

resource "aws_api_gateway_integration" "customers_post" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.customers.id
  http_method             = aws_api_gateway_method.customers_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.users_invoke_arn
}

# ---- GET /customers/{id} ----
resource "aws_api_gateway_method" "customer_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customer_id.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.cognito_jwt.id
  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "customer_get" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.customer_id.id
  http_method             = aws_api_gateway_method.customer_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.users_invoke_arn
}

# ---- PUT /customers/{id} ----
resource "aws_api_gateway_method" "customer_put" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customer_id.id
  http_method   = "PUT"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.cognito_jwt.id
  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "customer_put" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.customer_id.id
  http_method             = aws_api_gateway_method.customer_put.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.users_invoke_arn
}

# ---- DELETE /customers/{id} ----
resource "aws_api_gateway_method" "customer_delete" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customer_id.id
  http_method   = "DELETE"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.cognito_jwt.id
  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "customer_delete" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.customer_id.id
  http_method             = aws_api_gateway_method.customer_delete.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.users_invoke_arn
}

# ---- GET /customers/search ----
# Same CUSTOM authorizer + AWS_PROXY-to-users-Lambda shape as the other
# business methods. The optional querystring params mirror customers_get's
# limit/cursor declaration and add the search terms name/email (all optional).
# No new aws_lambda_permission is needed: aws_lambda_permission.api_gw_users
# with source_arn "${execution_arn}/*/*" already authorizes every method,
# including this one.
resource "aws_api_gateway_method" "customer_search_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customer_search.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.cognito_jwt.id
  request_parameters = {
    "method.request.querystring.name"   = false
    "method.request.querystring.email"  = false
    "method.request.querystring.limit"  = false
    "method.request.querystring.cursor" = false
  }
}

resource "aws_api_gateway_integration" "customer_search_get" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.customer_search.id
  http_method             = aws_api_gateway_method.customer_search_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.users_invoke_arn
}

# --------------------------------------------------------------------- #
# CORS: OPTIONS preflight on both resources (MOCK integration).
# --------------------------------------------------------------------- #

# ---- OPTIONS /customers ----
resource "aws_api_gateway_method" "customers_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customers.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "customers_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customers.id
  http_method = aws_api_gateway_method.customers_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "customers_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customers.id
  http_method = aws_api_gateway_method.customers_options.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "customers_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customers.id
  http_method = aws_api_gateway_method.customers_options.http_method
  status_code = aws_api_gateway_method_response.customers_options.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'${local.cors_headers}'"
    "method.response.header.Access-Control-Allow-Methods" = "'${local.cors_methods}'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${local.cors_origin}'"
  }
  depends_on = [aws_api_gateway_integration.customers_options]
}

# ---- OPTIONS /customers/{id} ----
resource "aws_api_gateway_method" "customer_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customer_id.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "customer_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customer_id.id
  http_method = aws_api_gateway_method.customer_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "customer_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customer_id.id
  http_method = aws_api_gateway_method.customer_options.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "customer_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customer_id.id
  http_method = aws_api_gateway_method.customer_options.http_method
  status_code = aws_api_gateway_method_response.customer_options.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'${local.cors_headers}'"
    "method.response.header.Access-Control-Allow-Methods" = "'${local.cors_methods}'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${local.cors_origin}'"
  }
  depends_on = [aws_api_gateway_integration.customer_options]
}

# ---- OPTIONS /customers/search ----
resource "aws_api_gateway_method" "customer_search_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.customer_search.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "customer_search_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customer_search.id
  http_method = aws_api_gateway_method.customer_search_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "customer_search_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customer_search.id
  http_method = aws_api_gateway_method.customer_search_options.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "customer_search_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.customer_search.id
  http_method = aws_api_gateway_method.customer_search_options.http_method
  status_code = aws_api_gateway_method_response.customer_search_options.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'${local.cors_headers}'"
    "method.response.header.Access-Control-Allow-Methods" = "'${local.cors_methods}'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${local.cors_origin}'"
  }
  depends_on = [aws_api_gateway_integration.customer_search_options]
}

# --------------------------------------------------------------------- #
# Permissions for API Gateway to invoke the Lambdas.
#   - the users Lambda for every business method
#   - the authorizer Lambda for the TOKEN authorizer
# --------------------------------------------------------------------- #
resource "aws_lambda_permission" "api_gw_users" {
  statement_id  = "AllowAPIGatewayInvokeUsers"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.users.function_name
  principal     = "apigateway.amazonaws.com"
  # Restrict to this API's methods only.
  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_gw_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/authorizers/*"
}

# --------------------------------------------------------------------- #
# Deployment + stage.
#
# The redeployment trigger hashes every resource/method/integration/
# authorization setting so the stage is redeployed whenever any of them
# change.
# --------------------------------------------------------------------- #
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_authorizer.cognito_jwt.id,

      aws_api_gateway_resource.customers.id,
      aws_api_gateway_resource.customer_id.id,

      aws_api_gateway_method.customers_get.id,
      aws_api_gateway_method.customers_get.authorization,
      aws_api_gateway_method.customers_get.authorizer_id,
      aws_api_gateway_integration.customers_get.id,

      aws_api_gateway_method.customers_post.id,
      aws_api_gateway_method.customers_post.authorization,
      aws_api_gateway_method.customers_post.authorizer_id,
      aws_api_gateway_integration.customers_post.id,

      aws_api_gateway_method.customer_get.id,
      aws_api_gateway_method.customer_get.authorization,
      aws_api_gateway_method.customer_get.authorizer_id,
      aws_api_gateway_integration.customer_get.id,

      aws_api_gateway_method.customer_put.id,
      aws_api_gateway_method.customer_put.authorization,
      aws_api_gateway_method.customer_put.authorizer_id,
      aws_api_gateway_integration.customer_put.id,

      aws_api_gateway_method.customer_delete.id,
      aws_api_gateway_method.customer_delete.authorization,
      aws_api_gateway_method.customer_delete.authorizer_id,
      aws_api_gateway_integration.customer_delete.id,

      aws_api_gateway_method.customers_options.id,
      aws_api_gateway_integration.customers_options.id,
      aws_api_gateway_integration_response.customers_options.id,

      aws_api_gateway_method.customer_options.id,
      aws_api_gateway_integration.customer_options.id,
      aws_api_gateway_integration_response.customer_options.id,

      aws_api_gateway_method.customer_search_get.id,
      aws_api_gateway_method.customer_search_get.authorization,
      aws_api_gateway_method.customer_search_get.authorizer_id,
      aws_api_gateway_integration.customer_search_get.id,

      aws_api_gateway_method.customer_search_options.id,
      aws_api_gateway_integration.customer_search_options.id,
      aws_api_gateway_integration_response.customer_search_options.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.customers_get,
    aws_api_gateway_integration.customers_post,
    aws_api_gateway_integration.customer_get,
    aws_api_gateway_integration.customer_put,
    aws_api_gateway_integration.customer_delete,
    aws_api_gateway_integration.customers_options,
    aws_api_gateway_integration.customer_options,
    aws_api_gateway_integration.customer_search_get,
    aws_api_gateway_integration.customer_search_options,
  ]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
  stage_name    = local.stage_name

  # Enable AWS X-Ray so a Trace spans API Gateway and the invoked Lambda
  # functions (Authorizer + Users), stitching the gateway and function
  # segments into one end-to-end trace (R1.2).
  xray_tracing_enabled = true

  # Per-request JSON access log to a dedicated, retention-managed log group
  # (R2.2). Depends (via the account setting) on the API Gateway CloudWatch
  # Logs role in observability.tf.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      resourcePath       = "$context.resourcePath"
      path               = "$context.path"
      protocol           = "$context.protocol"
      status             = "$context.status"
      responseLatency    = "$context.responseLatency"
      integrationStatus  = "$context.integrationStatus"
      integrationLatency = "$context.integrationLatency"
      authorizerError    = "$context.authorizer.error"
    })
  }

  # The account-level CloudWatch Logs role must exist before the stage enables
  # logging, or API Gateway rejects the stage update.
  depends_on = [aws_api_gateway_account.this]

  tags = {
    Name        = "${local.api_name}-${local.stage_name}"
    Environment = var.environment
    Project     = var.project
  }
}

# --------------------------------------------------------------------- #
# Access-log group + execution logging (task 2.2).
# --------------------------------------------------------------------- #

# Dedicated CloudWatch log group for the Prod stage's per-request access logs,
# separate from the Lambda log groups and from execution logs. Retention uses
# the same configurable variable as the rest of the platform (R2.2, R3.1).
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.api_name}/${local.stage_name}/access"
  retention_in_days = var.log_retention_in_days

  tags = {
    Name        = "/aws/apigateway/${local.api_name}/${local.stage_name}/access"
    Environment = var.environment
    Project     = var.project
  }
}

# Stage-wide execution logging + detailed CloudWatch metrics (R2.1, R2.5).
# logging_level = INFO records request/response and errors. data_trace_enabled
# stays false so full request/response bodies (which may carry customer PII)
# are not written to logs.
resource "aws_api_gateway_method_settings" "prod_all" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled    = true
    logging_level      = "INFO"
    data_trace_enabled = false
  }

  depends_on = [aws_api_gateway_account.this]
}

# --------------------------------------------------------------------- #
# Outputs.
# --------------------------------------------------------------------- #
output "api_invoke_url" {
  description = "Base invoke URL for the Prod stage of the Customer Management Platform API."
  value       = aws_api_gateway_stage.prod.invoke_url
}

output "api_execution_arn" {
  description = "Execution ARN of the REST API (used for Lambda permissions / authorizers)."
  value       = aws_api_gateway_rest_api.api.execution_arn
}

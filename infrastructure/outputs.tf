# Outputs for the Customer Management Platform infrastructure.
#
# Intentionally empty for the foundation task. Output blocks are added here as
# resources are introduced by later tasks (DynamoDB table name/ARN, Cognito
# user pool id and app client id, the API Gateway invoke URL, etc.).
# --------------------------------------------------------------------------- #
# DynamoDB (Customer_Store)
# --------------------------------------------------------------------------- #
output "customers_table_name" {
  description = "Name of the customers DynamoDB table."
  value       = aws_dynamodb_table.customers_table.name
}

output "customers_table_arn" {
  description = "ARN of the customers DynamoDB table."
  value       = aws_dynamodb_table.customers_table.arn
}

# --------------------------------------------------------------------------- #
# Cognito (task 11)
#
# These feed the Lambda Authorizer environment variables wired in task 12.2:
#   USER_POOL_ID           <- cognito_user_pool_id
#   APPLICATION_CLIENT_ID  <- cognito_user_pool_client_id
# and are also used by the integration tests to obtain a real JWT.
# --------------------------------------------------------------------------- #
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (authorizer USER_POOL_ID)."
  value       = aws_cognito_user_pool.pool.id
}

output "cognito_user_pool_client_id" {
  description = "Cognito User Pool app client ID (authorizer APPLICATION_CLIENT_ID)."
  value       = aws_cognito_user_pool_client.client.id
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN."
  value       = aws_cognito_user_pool.pool.arn
}

output "cognito_domain_url" {
  description = "Cognito hosted UI domain URL."
  value       = "https://${aws_cognito_user_pool_domain.domain.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

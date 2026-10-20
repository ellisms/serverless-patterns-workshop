# DynamoDB table for storing customer records (Customer_Store).
#
# Single table keyed by customerId. Customer items and email-guard items share
# the table, distinguished by the customerId value (a UUIDv4 for customers and
# "EMAIL#<emailLower>" for guard items). A GSI on emailLower supports looking up
# the customer that owns an email. No prevent_destroy / deletion protection is
# set, so the stack can be torn down with `terraform destroy`.
resource "aws_dynamodb_table" "customers_table" {
  name         = var.customers_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "customerId"

  attribute {
    name = "customerId"
    type = "S"
  }

  # emailLower backs the case-insensitive email-uniqueness guard and the GSI.
  attribute {
    name = "emailLower"
    type = "S"
  }

  # Look up the customer that owns an email. customerId (the table hash key) is
  # always projected into a GSI automatically, so KEYS_ONLY projects
  # emailLower -> customerId.
  global_secondary_index {
    name            = "email-index"
    hash_key        = "emailLower"
    projection_type = "KEYS_ONLY"
  }

  # Point-in-time recovery with a 35-day retention window (durability).
  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = 35
  }

  # Server-side encryption using the AWS owned key (no customer/AWS managed
  # KMS key). Leaving enabled = false keeps the default AWS owned key, which
  # still encrypts data at rest at no additional cost.
  server_side_encryption {
    enabled = false
  }

  tags = {
    Name        = var.customers_table_name
    Environment = var.environment
    Project     = var.project
  }
}

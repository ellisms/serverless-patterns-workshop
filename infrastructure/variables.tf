# Input variables for the Customer Management Platform infrastructure.
#
# Resource names are derived from a shared base-name prefix (mirroring the
# reference implementation in /workshop/option1), with explicit overrides
# available for the DynamoDB table, Cognito user pool / app client, and the
# admin group. The region is never declared here: it comes from the active
# AWS profile / AWS_REGION.

# --------------------------------------------------------------------------- #
# Naming / tagging
# --------------------------------------------------------------------------- #
variable "workshop_stack_base_name" {
  description = "Base name used to prefix Customer Management Platform resources."
  type        = string
  default     = "customer-management"
}

variable "environment" {
  description = "Deployment environment name (applied as a default tag)."
  type        = string
  default     = "Workshop"
}

variable "project" {
  description = "Project name (applied as a default tag)."
  type        = string
  default     = "CustomerManagementPlatform"
}

# --------------------------------------------------------------------------- #
# DynamoDB
# --------------------------------------------------------------------------- #
variable "customers_table_name" {
  description = "Name of the DynamoDB table that stores customer records."
  type        = string
  default     = "customer-management_customers"
}

# --------------------------------------------------------------------------- #
# Cognito
# --------------------------------------------------------------------------- #
variable "user_pool_name" {
  description = "Name of the Cognito user pool used to issue JWTs."
  type        = string
  default     = "customer-management_UserPool"
}

variable "app_client_name" {
  description = "Name of the Cognito user pool app client."
  type        = string
  default     = "customer-management-client"
}

variable "admin_group_name" {
  description = "Name of the Cognito group whose members are treated as administrators (surfaced to the authorizer as ADMIN_GROUP_NAME)."
  type        = string
  default     = "Administrators"
}

# --------------------------------------------------------------------------- #
# Observability
# --------------------------------------------------------------------------- #
variable "log_retention_in_days" {
  description = "Retention period (in days) for the Lambda CloudWatch log groups."
  type        = number
  default     = 14
}

variable "search_latency_alarm_threshold_ms" {
  description = "Threshold in milliseconds for the customer-search latency CloudWatch alarm."
  type        = number
  default     = 2000
}

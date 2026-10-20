# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# --------------------------------------------------------------------------- #
# Effective resource names.
#
# Each stage (dev/prod) sets a distinct workshop_stack_base_name, so by default
# every named resource derives its name from that base name and becomes
# stage-unique. An explicit var still overrides (back-compat with the original
# single-stack "customer-management" deployment). This prevents cross-stage
# name collisions (e.g. the DynamoDB table) when only the base name is passed.
# --------------------------------------------------------------------------- #
locals {
  customers_table_name = coalesce(var.customers_table_name, "${var.workshop_stack_base_name}_customers")
  user_pool_name       = coalesce(var.user_pool_name, "${var.workshop_stack_base_name}_UserPool")
  app_client_name      = coalesce(var.app_client_name, "${var.workshop_stack_base_name}-client")
}

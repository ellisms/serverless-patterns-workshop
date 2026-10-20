# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Shared pytest fixtures/config for the Customer Management Platform tests."""
import os

# Ensure a region is always present for boto3/module import (overridden by moto
# in unit tests). Real integration tests use the ambient AWS_REGION/creds.
os.environ.setdefault("AWS_DEFAULT_REGION", "us-west-2")
os.environ.setdefault("AWS_REGION", "us-west-2")

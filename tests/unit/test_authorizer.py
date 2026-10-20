# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Unit tests for the Lambda authorizer, with PyJWT mocked (no network/JWKS)."""
import importlib
import sys
from unittest import mock

import pytest

APP_CLIENT = "test-client-id"
POOL = "us-west-2_testpool"


@pytest.fixture
def authz(monkeypatch):
    """Import lambda_authorizer with env set and jwt.PyJWKClient mocked."""
    monkeypatch.setenv("AWS_REGION", "us-west-2")
    monkeypatch.setenv("USER_POOL_ID", POOL)
    monkeypatch.setenv("APPLICATION_CLIENT_ID", APP_CLIENT)
    monkeypatch.setenv("ADMIN_GROUP_NAME", "Administrators")

    # Patch PyJWKClient so import doesn't try to reach the JWKS endpoint.
    with mock.patch("jwt.PyJWKClient") as mock_jwks:
        mock_jwks.return_value.get_signing_key_from_jwt.return_value = mock.Mock(key="k")
        sys.modules.pop("lambda_authorizer", None)
        import lambda_authorizer as mod
        importlib.reload(mod)
        yield mod


def _event(token="Bearer abc", method_arn="arn:aws:execute-api:us-west-2:1:api/Prod/GET/customers"):
    return {"authorizationToken": token, "methodArn": method_arn}


def test_valid_id_token_allows(authz):
    claims = {"sub": "user-1", "token_use": "id", "aud": APP_CLIENT,
              "email": "u@x.com", "cognito:groups": ["Administrators"]}
    with mock.patch("jwt.decode", return_value=claims):
        policy = authz.lambda_handler(_event(), None)
    assert policy["principalId"] == "user-1"
    stmt = policy["policyDocument"]["Statement"][0]
    assert stmt["Effect"] == "Allow"
    assert stmt["Resource"].endswith("/*/*")
    assert policy["context"]["userId"] == "user-1"
    assert policy["context"]["email"] == "u@x.com"
    assert policy["context"]["isAdmin"] == "true"


def test_valid_access_token_non_admin(authz):
    claims = {"sub": "user-2", "token_use": "access", "client_id": APP_CLIENT}
    with mock.patch("jwt.decode", return_value=claims):
        policy = authz.lambda_handler(_event(), None)
    assert policy["context"]["isAdmin"] == "false"
    assert policy["context"]["email"] == ""


def test_wrong_audience_unauthorized(authz):
    claims = {"sub": "u", "token_use": "id", "aud": "some-other-client"}
    with mock.patch("jwt.decode", return_value=claims):
        with pytest.raises(Exception, match="Unauthorized"):
            authz.lambda_handler(_event(), None)


def test_bad_token_use_unauthorized(authz):
    claims = {"sub": "u", "token_use": "refresh", "aud": APP_CLIENT}
    with mock.patch("jwt.decode", return_value=claims):
        with pytest.raises(Exception, match="Unauthorized"):
            authz.lambda_handler(_event(), None)


def test_decode_error_unauthorized(authz):
    with mock.patch("jwt.decode", side_effect=ValueError("expired")):
        with pytest.raises(Exception, match="Unauthorized"):
            authz.lambda_handler(_event(), None)


def test_failure_logs_no_token_contents(authz, capsys):
    with mock.patch("jwt.decode", side_effect=ValueError("expired")):
        with pytest.raises(Exception, match="Unauthorized"):
            authz.lambda_handler(_event(token="Bearer super-secret-jwt"), None)
    out = capsys.readouterr().out
    assert "authorization_failed" in out
    assert "super-secret-jwt" not in out  # never log token contents (R4.7)

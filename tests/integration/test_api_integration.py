# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Integration tests against a DEPLOYED stack.

Gated by environment variables so they run only post-deploy (never on PRs
without a stack). Required env:
  API_BASE_URL          e.g. https://xxxx.execute-api.us-west-2.amazonaws.com/Prod
  COGNITO_USER_POOL_ID
  COGNITO_CLIENT_ID
Optional (a temp user is created/confirmed if not supplied):
  TEST_USERNAME, TEST_PASSWORD
AWS credentials must be present in the environment (OIDC role in CI).
"""
import os
import uuid

import pytest

pytestmark = pytest.mark.integration

API = os.environ.get("API_BASE_URL")
POOL = os.environ.get("COGNITO_USER_POOL_ID")
CLIENT = os.environ.get("COGNITO_CLIENT_ID")

# Skip the whole module unless a deployed target is configured.
pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not (API and POOL and CLIENT),
        reason="integration target not configured (API_BASE_URL/COGNITO_* unset)",
    ),
]


@pytest.fixture(scope="module")
def token():
    """Obtain a Cognito id token, creating a temp confirmed user if needed."""
    import boto3
    region = os.environ.get("AWS_REGION", "us-west-2")
    idp = boto3.client("cognito-idp", region_name=region)
    username = os.environ.get("TEST_USERNAME") or f"itest-{uuid.uuid4().hex[:8]}@example.com"
    password = os.environ.get("TEST_PASSWORD") or f"Itest!{uuid.uuid4().hex[:10]}A1"
    created = False
    if not os.environ.get("TEST_USERNAME"):
        idp.admin_create_user(
            UserPoolId=POOL, Username=username,
            MessageAction="SUPPRESS",
            UserAttributes=[{"Name": "email", "Value": username},
                            {"Name": "email_verified", "Value": "true"}],
        )
        idp.admin_set_user_password(
            UserPoolId=POOL, Username=username, Password=password, Permanent=True)
        created = True
    try:
        resp = idp.admin_initiate_auth(
            UserPoolId=POOL, ClientId=CLIENT,
            AuthFlow="ADMIN_USER_PASSWORD_AUTH",
            AuthParameters={"USERNAME": username, "PASSWORD": password},
        )
        yield resp["AuthenticationResult"]["IdToken"]
    finally:
        if created:
            idp.admin_delete_user(UserPoolId=POOL, Username=username)


@pytest.fixture(scope="module")
def http():
    import requests
    return requests


def _auth(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def test_no_token_is_401(http):
    r = http.get(f"{API}/customers", timeout=30)
    assert r.status_code == 401


def test_crud_and_search_happy_path(http, token):
    h = _auth(token)
    email = f"itest-{uuid.uuid4().hex[:8]}@example.com"

    # create
    r = http.post(f"{API}/customers", headers=h,
                  json={"name": "Integration Tester", "email": email}, timeout=30)
    assert r.status_code == 201, r.text
    cid = r.json()["customerId"]

    try:
        # get
        r = http.get(f"{API}/customers/{cid}", headers=h, timeout=30)
        assert r.status_code == 200 and r.json()["customerId"] == cid

        # list
        r = http.get(f"{API}/customers?limit=5", headers=h, timeout=30)
        assert r.status_code == 200 and "items" in r.json()

        # search by name (case-insensitive)
        r = http.get(f"{API}/customers/search", headers=h,
                     params={"name": "integration"}, timeout=30)
        assert r.status_code == 200
        assert any(c["customerId"] == cid for c in r.json()["items"])

        # update
        r = http.put(f"{API}/customers/{cid}", headers=h,
                     json={"name": "Integration Tester 2"}, timeout=30)
        assert r.status_code == 200 and r.json()["name"] == "Integration Tester 2"
    finally:
        # delete (cleanup)
        r = http.delete(f"{API}/customers/{cid}", headers=h, timeout=30)
        assert r.status_code == 200
        # confirm gone
        r = http.get(f"{API}/customers/{cid}", headers=h, timeout=30)
        assert r.status_code == 404

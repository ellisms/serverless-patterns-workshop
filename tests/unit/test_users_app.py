# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Unit tests for the users Lambda (src/users/app.py), DynamoDB mocked via moto."""
import importlib
import json

import boto3
import pytest
from moto import mock_aws

TABLE = "test-customers"


@pytest.fixture
def app(monkeypatch):
    """Import app with a mocked DynamoDB table and TABLE_NAME set."""
    monkeypatch.setenv("TABLE_NAME", TABLE)
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-west-2")
    with mock_aws():
        ddb = boto3.resource("dynamodb", region_name="us-west-2")
        ddb.create_table(
            TableName=TABLE,
            AttributeDefinitions=[
                {"AttributeName": "customerId", "AttributeType": "S"},
                {"AttributeName": "emailLower", "AttributeType": "S"},
            ],
            KeySchema=[{"AttributeName": "customerId", "KeyType": "HASH"}],
            GlobalSecondaryIndexes=[{
                "IndexName": "email-index",
                "KeySchema": [{"AttributeName": "emailLower", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "KEYS_ONLY"},
            }],
            BillingMode="PAY_PER_REQUEST",
        )
        import app as app_module
        importlib.reload(app_module)
        # Reset cached clients so they bind to the moto session.
        app_module._table = None
        app_module._client = None
        yield app_module


def _event(method, resource, body=None, path_id=None, qs=None):
    ev = {"httpMethod": method, "resource": resource}
    if body is not None:
        ev["body"] = body if isinstance(body, str) else json.dumps(body)
    if path_id is not None:
        ev["pathParameters"] = {"id": path_id}
    if qs is not None:
        ev["queryStringParameters"] = qs
    ev.setdefault("requestContext", {"requestId": "test-req-1"})
    return ev


class Ctx:
    aws_request_id = "lambda-req-1"


# ----------------------------- validation helpers ------------------------- #

def test_parse_body_rejects_non_json(app):
    with pytest.raises(app.ClientInputError):
        app._parse_body({"body": "not json"})


def test_parse_body_rejects_json_array(app):
    with pytest.raises(app.ClientInputError):
        app._parse_body({"body": "[1,2,3]"})


def test_validate_attributes_rejects_unknown_field(app):
    with pytest.raises(app.ClientInputError):
        app._validate_attributes({"name": "x", "role": "admin"})


def test_validate_attributes_rejects_bad_email(app):
    with pytest.raises(app.ClientInputError):
        app._validate_attributes({"email": "not-an-email"})


def test_validate_attributes_requires_one_field(app):
    with pytest.raises(app.ClientInputError):
        app._validate_attributes({}, require_any=True)


def test_validate_customer_id_bounds(app):
    with pytest.raises(app.ClientInputError):
        app._validate_customer_id("")
    with pytest.raises(app.ClientInputError):
        app._validate_customer_id("x" * 129)
    assert app._validate_customer_id("ok") == "ok"


def test_normalize_email(app):
    assert app._normalize_email("  Ada@X.CoM ") == "ada@x.com"


# ----------------------------- pagination codec --------------------------- #

def test_cursor_roundtrip(app):
    key = {"customerId": "abc"}
    tok = app._encode_cursor(key)
    assert app._decode_cursor(tok) == key


def test_cursor_corrupt_rejected(app):
    with pytest.raises(app.ClientInputError):
        app._decode_cursor("!!!not-base64!!!")


def test_page_size_default_and_cap(app):
    assert app._page_size(None) == app.DEFAULT_PAGE_SIZE
    assert app._page_size({"limit": "1000"}) == app.MAX_PAGE_SIZE
    with pytest.raises(app.ClientInputError):
        app._page_size({"limit": "0"})


# ----------------------------- response helpers --------------------------- #

def test_response_headers(app):
    r = app._response(200, {"ok": True})
    assert r["statusCode"] == 200
    assert r["headers"]["Content-Type"] == "application/json"
    assert r["headers"]["Cache-Control"] == "no-store"
    assert json.loads(r["body"]) == {"ok": True}


# ----------------------------- CRUD via handler --------------------------- #

def test_create_then_get_roundtrip(app):
    resp = app.lambda_handler(
        _event("POST", "/customers", {"name": "Ada", "email": "ada@x.com"}), Ctx())
    assert resp["statusCode"] == 201
    rec = json.loads(resp["body"])
    cid = rec["customerId"]
    assert rec["name"] == "Ada" and "emailLower" not in rec and "entity" not in rec

    got = app.lambda_handler(_event("GET", "/customers/{id}", path_id=cid), Ctx())
    assert got["statusCode"] == 200
    assert json.loads(got["body"])["customerId"] == cid


def test_create_duplicate_email_409(app):
    app.lambda_handler(_event("POST", "/customers", {"email": "dup@x.com"}), Ctx())
    resp = app.lambda_handler(
        _event("POST", "/customers", {"email": "DUP@X.com"}), Ctx())
    assert resp["statusCode"] == 409


def test_get_missing_404(app):
    resp = app.lambda_handler(_event("GET", "/customers/{id}", path_id="nope"), Ctx())
    assert resp["statusCode"] == 404


def test_list_empty_200(app):
    resp = app.lambda_handler(_event("GET", "/customers"), Ctx())
    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["items"] == []


def test_update_and_delete(app):
    cid = json.loads(app.lambda_handler(
        _event("POST", "/customers", {"name": "Bob"}), Ctx())["body"])["customerId"]
    up = app.lambda_handler(
        _event("PUT", "/customers/{id}", {"name": "Bobby"}, path_id=cid), Ctx())
    assert up["statusCode"] == 200 and json.loads(up["body"])["name"] == "Bobby"
    dl = app.lambda_handler(_event("DELETE", "/customers/{id}", path_id=cid), Ctx())
    assert dl["statusCode"] == 200
    assert app.lambda_handler(
        _event("GET", "/customers/{id}", path_id=cid), Ctx())["statusCode"] == 404


def test_bad_body_400(app):
    resp = app.lambda_handler(_event("POST", "/customers", "not json"), Ctx())
    assert resp["statusCode"] == 400


def test_undefined_method_405(app):
    resp = app.lambda_handler(_event("PATCH", "/customers"), Ctx())
    assert resp["statusCode"] == 405


# ----------------------------- search ------------------------------------- #

def test_search_by_name_case_insensitive(app):
    app.lambda_handler(_event("POST", "/customers", {"name": "Alice"}), Ctx())
    app.lambda_handler(_event("POST", "/customers", {"name": "Bob"}), Ctx())
    resp = app.lambda_handler(
        _event("GET", "/customers/search", qs={"name": "ali"}), Ctx())
    assert resp["statusCode"] == 200
    items = json.loads(resp["body"])["items"]
    assert len(items) == 1 and items[0]["name"] == "Alice"


def test_search_requires_a_term(app):
    resp = app.lambda_handler(_event("GET", "/customers/search", qs={}), Ctx())
    assert resp["statusCode"] == 400


# ----------------------------- structured logging ------------------------- #

def test_log_single_json_line(app, capsys):
    app._log("INFO", "hello", a=1)
    out = capsys.readouterr().out.strip().splitlines()
    assert len(out) == 1
    rec = json.loads(out[0])
    assert rec["level"] == "INFO" and rec["message"] == "hello" and rec["a"] == 1


def test_log_never_raises_on_unserializable(app):
    class X:
        pass
    # default=str makes this safe; must not raise.
    app._log("INFO", "obj", thing=X())


def test_handler_emits_one_request_log(app, capsys):
    app.lambda_handler(_event("GET", "/customers"), Ctx())
    lines = [l for l in capsys.readouterr().out.splitlines() if l.strip()]
    completed = [json.loads(l) for l in lines
                 if '"request_completed"' in l]
    assert len(completed) == 1
    rec = completed[0]
    assert rec["method"] == "GET" and rec["resource"] == "/customers"
    assert rec["status"] == 200 and rec["correlationId"] == "test-req-1"
    assert isinstance(rec["latencyMs"], (int, float))

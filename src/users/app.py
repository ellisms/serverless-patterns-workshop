# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Customers service Lambda handler.

Processes API Gateway proxy events and implements CRUD operations for customer
records stored in DynamoDB (the Customer_Store).

Routes:
    GET    /customers         List customers (paginated)
    GET    /customers/{id}    Get a single customer
    POST   /customers         Create a customer (server-generated UUID)
    PUT    /customers/{id}    Update an existing customer
    DELETE /customers/{id}    Delete a customer

The DynamoDB table name is read from the TABLE_NAME environment variable.

This module currently defines the shared field-constraint constants used by the
validation, persistence, and routing logic implemented in later tasks.
"""

import base64
import json
import os
import re
import time
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Attr
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

# Serializes native Python values into the DynamoDB wire format required by the
# low-level client's transact_write_items (the resource API has no transaction
# method, so transactional writes go through the client).
_SERIALIZER = TypeSerializer()


def _marshal(item):
    """Convert a plain-Python item dict into DynamoDB-typed attribute values."""
    return {key: _SERIALIZER.serialize(value) for key, value in item.items()}


# --------------------------------------------------------------------------- #
# DynamoDB access layer
#
# The table name comes from the TABLE_NAME environment variable. The boto3
# resource/table and the low-level client are created once per execution
# environment (lazily) so warm invocations reuse the same connection pool.
#
# The resource Table is used for single-item operations (auto-marshals native
# Python types). Transactional writes have no resource-level API, so they go
# through a dedicated low-level client with items marshalled via _marshal; the
# resource's own client is intentionally not reused for this because it carries
# document-type transformers that would double-serialize the typed items.
# --------------------------------------------------------------------------- #
_table = None
_client = None


def _get_table():
    """Return the cached DynamoDB Table resource, creating it on first use.

    Reads the table name from the TABLE_NAME environment variable. Lazy
    initialization keeps imports cheap and lets tests set TABLE_NAME before the
    first call.
    """
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def _get_client():
    """Return the cached low-level DynamoDB client used for transactions.

    A standalone client (not the resource's client) so that items already
    marshalled into DynamoDB wire format are sent as-is.
    """
    global _client
    if _client is None:
        _client = boto3.client("dynamodb")
    return _client


# --------------------------------------------------------------------------- #
# Field-constraint constants
#
# These values are the single source of truth for request validation and are
# shared by the validation helpers, CRUD operations, and the router.
# --------------------------------------------------------------------------- #

# Attributes a client is allowed to set/modify. "customerId" and the audit
# timestamps (createdAt/updatedAt) are server-managed and intentionally
# excluded, so any other field in a request body is rejected (R2.7, R4.6).
ALLOWED_ATTRIBUTES = frozenset({"name", "email", "phone"})

# Per-field length and format constraints (R2.6).
NAME_MAX_LENGTH = 256       # name: non-empty string, trimmed length <= 256.
EMAIL_MAX_LENGTH = 254      # email: syntactically valid, length <= 254.
PHONE_MIN_LENGTH = 3        # phone: 3-32 chars of digits, spaces, and + ( ) -.
PHONE_MAX_LENGTH = 32

# Syntactic email validation. Original casing is preserved on the record;
# the normalized (lower-cased) form backs the uniqueness guard and GSI.
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# Allowed characters for a phone value: digits, spaces, and + ( ) -.
PHONE_RE = re.compile(r"^[0-9 +()\-]+$")

# Customer_Id bounds. Ids outside this range are rejected before any DynamoDB
# call (R3.3, R5.3).
CUSTOMER_ID_MAX_LENGTH = 128

# Pagination bounds for list operations (R3.4).
DEFAULT_PAGE_SIZE = 25
MAX_PAGE_SIZE = 100

# --------------------------------------------------------------------------- #
# Customer-search constants
#
# Search reuses NAME_MAX_LENGTH (256) / EMAIL_MAX_LENGTH (254) above for its
# Search_Term length limits and the existing pagination bounds. These values
# are specific to the search endpoint: the custom CloudWatch namespace/metric
# for the Search_Latency_Metric (R8.2) and the whitelist of query-string keys a
# Search_Request may carry (R4.3).
# --------------------------------------------------------------------------- #
SEARCH_METRIC_NAMESPACE = "CustomerManagementPlatform/Search"
SEARCH_METRIC_NAME = "SearchLatencyMs"

# Query-string keys a Search_Request may supply: the two Search_Terms plus the
# existing pagination controls (``cursor`` and its ``next`` alias). Any other
# key is an unexpected criterion and rejected with 400 (R4.3).
ALLOWED_SEARCH_PARAMS = frozenset({"name", "email", "limit", "cursor", "next"})


class ClientInputError(Exception):
    """Raised for invalid client input; mapped to an HTTP 400 response.

    Every validation/parsing failure in this module raises this exception so the
    router can map it to a 400 in one place (R2.4, R2.5, R2.6, R2.7, R4.4, R4.5,
    R4.6, R3.3, R5.3).
    """


# --------------------------------------------------------------------------- #
# Request parsing, validation, and normalization helpers
# --------------------------------------------------------------------------- #
def _parse_body(event):
    """Decode and parse the JSON request body from an API Gateway proxy event.

    base64-decodes the body first when the event is flagged ``isBase64Encoded``,
    then ``json.loads`` the result and requires it to be a JSON object. Non-JSON
    or non-object bodies raise ``ClientInputError`` (-> 400) (R2.5, R4.4).
    """
    raw = event.get("body")
    if raw is None or raw == "":
        raise ClientInputError("Request body is required.")

    if event.get("isBase64Encoded"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except (ValueError, TypeError, UnicodeDecodeError):
            raise ClientInputError("Request body is not valid base64/UTF-8.")

    try:
        parsed = json.loads(raw)
    except (ValueError, TypeError):
        raise ClientInputError("Request body must be valid JSON.")

    if not isinstance(parsed, dict):
        raise ClientInputError("Request body must be a JSON object.")
    return parsed


def _validate_attributes(data, require_any=True):
    """Whitelist and validate client-supplied attributes.

    Only attributes in ``ALLOWED_ATTRIBUTES`` ({name, email, phone}) are
    accepted; any other field - including an attempt to set the server-managed
    ``customerId`` - is rejected (R2.7, R4.6). Each supplied field is checked
    against the design's field constraints (R2.6, R4.5), and when
    ``require_any`` is set at least one field must be present (R2.4, R4.1).
    ``ClientInputError`` names the offending field.

    Returns the validated attributes with ``name`` trimmed.
    """
    unknown = set(data) - ALLOWED_ATTRIBUTES
    if unknown:
        raise ClientInputError(
            "Unexpected field(s): " + ", ".join(sorted(unknown))
        )

    attrs = {}

    if "name" in data:
        name = data["name"]
        if not isinstance(name, str) or not name.strip():
            raise ClientInputError("'name' must be a non-empty string.")
        trimmed = name.strip()
        if len(trimmed) > NAME_MAX_LENGTH:
            raise ClientInputError(
                f"'name' must be at most {NAME_MAX_LENGTH} characters."
            )
        attrs["name"] = trimmed

    if "email" in data:
        email = data["email"]
        if not isinstance(email, str) or not EMAIL_RE.match(email):
            raise ClientInputError("'email' must be a valid email address.")
        if len(email) > EMAIL_MAX_LENGTH:
            raise ClientInputError(
                f"'email' must be at most {EMAIL_MAX_LENGTH} characters."
            )
        attrs["email"] = email

    if "phone" in data:
        phone = data["phone"]
        if (
            not isinstance(phone, str)
            or not (PHONE_MIN_LENGTH <= len(phone) <= PHONE_MAX_LENGTH)
            or not PHONE_RE.match(phone)
        ):
            raise ClientInputError(
                f"'phone' must be {PHONE_MIN_LENGTH}-{PHONE_MAX_LENGTH} "
                "characters of digits, spaces, and + ( ) -."
            )
        attrs["phone"] = phone

    if require_any and not attrs:
        raise ClientInputError(
            "At least one of 'name', 'email', or 'phone' is required."
        )
    return attrs


def _normalize_email(email):
    """Return the normalized form of an email used for uniqueness guards."""
    return email.strip().lower()


def _now_iso():
    """Return the current UTC time as an ISO-8601 string (audit timestamps)."""
    return datetime.now(timezone.utc).isoformat()


def _validate_customer_id(customer_id):
    """Validate a path Customer_Id before any DynamoDB call (R3.3, R5.3).

    Rejects an empty id or one longer than ``CUSTOMER_ID_MAX_LENGTH`` with
    ``ClientInputError`` (-> 400). Returns the validated id.
    """
    if not customer_id:
        raise ClientInputError("Customer_Id is invalid.")
    if len(customer_id) > CUSTOMER_ID_MAX_LENGTH:
        raise ClientInputError(
            f"Customer_Id must be at most {CUSTOMER_ID_MAX_LENGTH} characters."
        )
    return customer_id


# --------------------------------------------------------------------------- #
# Pagination-cursor codec
#
# The DynamoDB Scan pagination key (LastEvaluatedKey) is an internal structure
# whose shape should not leak to clients. These helpers wrap it in an opaque,
# URL-safe base64 token that round-trips back to the original key, and reject a
# corrupt cursor with a 400 rather than surfacing an internal error (R3.4).
# --------------------------------------------------------------------------- #
def _encode_cursor(last_evaluated_key):
    """Encode a DynamoDB ``LastEvaluatedKey`` into an opaque cursor string.

    Returns ``None`` when there is no key (the final page). Otherwise returns a
    URL-safe base64 string that ``_decode_cursor`` reverses exactly (R3.4).
    """
    if not last_evaluated_key:
        return None
    raw = json.dumps(last_evaluated_key, separators=(",", ":"), sort_keys=True)
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii")


def _decode_cursor(cursor):
    """Decode an opaque cursor back into a DynamoDB ``LastEvaluatedKey`` dict.

    Returns ``None`` for an absent/empty cursor. A cursor that is not valid
    base64, not valid UTF-8/JSON, or does not decode to a JSON object is treated
    as corrupt and raises ``ClientInputError`` (-> 400) so an internal error is
    never leaked (R3.4).
    """
    if cursor is None or cursor == "":
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor.encode("ascii"))
        decoded = json.loads(raw.decode("utf-8"))
    except (ValueError, TypeError, UnicodeDecodeError):
        raise ClientInputError("Invalid pagination cursor.")
    if not isinstance(decoded, dict):
        raise ClientInputError("Invalid pagination cursor.")
    return decoded


def _page_size(params):
    """Resolve the list page size from the query-string parameters.

    ``params`` is the event's ``queryStringParameters`` and may be ``None``.
    Defaults to ``DEFAULT_PAGE_SIZE`` when ``limit`` is absent and caps the
    result at ``MAX_PAGE_SIZE``. A ``limit`` that is not a positive integer is
    rejected with ``ClientInputError`` (-> 400) (R3.4).
    """
    if not params or params.get("limit") is None:
        return DEFAULT_PAGE_SIZE

    raw = params["limit"]
    try:
        size = int(raw)
    except (ValueError, TypeError):
        raise ClientInputError("'limit' must be a positive integer.")
    if size < 1:
        raise ClientInputError("'limit' must be a positive integer.")
    return min(size, MAX_PAGE_SIZE)


# --------------------------------------------------------------------------- #
# Customer-search request-processing helpers
#
# These helpers are pure: they validate a Search_Request's criteria and build
# the DynamoDB filter but perform no I/O. ``search_customers`` (a later task)
# composes them with a paginated Scan. Keeping them side-effect-free means every
# invalid-input rejection happens before any Customer_Store read (R2.4, R3.4,
# R4.2, R4.3) and the pure logic is exercised directly by property tests.
# --------------------------------------------------------------------------- #
def _validate_search_terms(params):
    """Validate a Search_Request's name/email Search_Terms (R2.4, R3.4, R4.2, R4.3).

    ``params`` is the event's ``queryStringParameters`` and may be ``None``.
    Every rejection raises ``ClientInputError`` (-> 400) and, because this helper
    does no I/O, necessarily happens before any Customer_Store read.

    Rejects any query key outside ``ALLOWED_SEARCH_PARAMS`` ({name, email, limit,
    cursor, next}), naming the unexpected key(s) (R4.3). For each supplied
    ``name``/``email`` Search_Term: the value must be a string, is trimmed, must
    not be empty/whitespace-only, and must not exceed its field limit
    (``NAME_MAX_LENGTH`` = 256, ``EMAIL_MAX_LENGTH`` = 254) - the error message
    names the offending term (R2.4, R3.4). At least one of ``name``/``email`` is
    required (R4.2).

    Returns the normalized ``(name_term_lower, email_term_lower)`` tuple, each
    the trimmed and lower-cased Search_Term or ``None`` when absent (R2.2, R3.2).
    """
    params = params or {}

    unexpected = set(params) - ALLOWED_SEARCH_PARAMS
    if unexpected:
        raise ClientInputError(
            "Unexpected search criterion(s): " + ", ".join(sorted(unexpected))
        )

    def _normalize_term(field, max_length):
        if field not in params:
            return None
        value = params[field]
        if not isinstance(value, str):
            raise ClientInputError(f"'{field}' must be a string.")
        trimmed = value.strip()
        if not trimmed:
            raise ClientInputError(f"'{field}' must not be empty.")
        if len(trimmed) > max_length:
            raise ClientInputError(
                f"'{field}' must be at most {max_length} characters."
            )
        return trimmed.lower()

    name_term_lower = _normalize_term("name", NAME_MAX_LENGTH)
    email_term_lower = _normalize_term("email", EMAIL_MAX_LENGTH)

    if name_term_lower is None and email_term_lower is None:
        raise ClientInputError(
            "At least one of 'name' or 'email' is required."
        )

    return name_term_lower, email_term_lower


def _build_search_filter(name_term_lower, email_term_lower):
    """Build the DynamoDB ``FilterExpression`` for a Search_Request (R4.1, R3.5).

    Always restricts the Scan to customer items with ``Attr("entity").eq(
    "CUSTOMER")`` so email-guard items never surface (R7.3). When an email
    Search_Term is present, ANDs ``Attr("emailLower").contains(email_term_lower)``
    for the case-insensitive email substring match; because ``emailLower`` only
    exists on records that have an email, this also excludes records lacking an
    email (R3.5).

    The name match is intentionally *not* placed in the DynamoDB
    ``FilterExpression``: the stored ``name`` keeps its original casing and has
    no lower-cased twin, so a case-insensitive substring test cannot be expressed
    server-side without a schema change. Instead the name Search_Term is returned
    alongside the filter so the caller can apply a case-insensitive post-filter
    (via ``_name_matches``) to the page's candidate items.

    Returns ``(filter_expression, name_term_lower)``; ``name_term_lower`` is
    ``None`` when no name Search_Term was supplied.
    """
    filter_expression = Attr("entity").eq("CUSTOMER")
    if email_term_lower is not None:
        filter_expression = filter_expression & Attr("emailLower").contains(
            email_term_lower
        )
    return filter_expression, name_term_lower


def _name_matches(item, name_term_lower):
    """Case-insensitive name post-filter for a candidate Customer_Record (R2.2, R2.5).

    Returns ``True`` only when ``item`` has a string ``name`` whose lower-cased
    value contains ``name_term_lower`` as a substring. An item without a ``name``
    (or whose ``name`` is not a string) returns ``False`` so missing-name records
    are excluded from a name Search_Result (R2.5).
    """
    name = item.get("name")
    if not isinstance(name, str):
        return False
    return name_term_lower in name.lower()


# --------------------------------------------------------------------------- #
# Search latency metric emitter
#
# The Search_Latency_Metric is recorded with the CloudWatch Embedded Metric
# Format (EMF): the Lambda writes one structured JSON log line to stdout and
# CloudWatch extracts the metric from the log group asynchronously. This keeps
# metric recording off the request's critical path - there is no PutMetricData
# API call and so no added request latency and no new IAM permission beyond the
# Logs access the function already holds (R8.3). The caller (the router) times
# the search branch and passes the elapsed milliseconds here.
# --------------------------------------------------------------------------- #
def _emit_search_latency(ms):
    """Emit the Search_Latency_Metric as one EMF log line (R8.1, R8.2, R8.3, R8.5).

    Writes a single Embedded Metric Format JSON object to stdout describing one
    metric, ``SearchLatencyMs`` (unit ``Milliseconds``), in the dedicated
    namespace ``CustomerManagementPlatform/Search`` with a single dimension
    ``Operation = "Search"`` so search latency is observable independently of the
    other Users_API operations (R8.2, R8.5). ``ms`` is the server-side elapsed
    time in milliseconds, stored as a number rounded to microsecond precision.

    Emission is best-effort and non-fatal: the entire body is wrapped so any
    serialization or I/O error is caught and logged server-side but never raised,
    guaranteeing metric emission can never fail a Search_Request (R8.3). Returns
    ``None``.
    """
    try:
        now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        emf = {
            "_aws": {
                "Timestamp": now_ms,
                "CloudWatchMetrics": [
                    {
                        "Namespace": SEARCH_METRIC_NAMESPACE,
                        "Dimensions": [["Operation"]],
                        "Metrics": [
                            {"Name": SEARCH_METRIC_NAME, "Unit": "Milliseconds"}
                        ],
                    }
                ],
            },
            "Operation": "Search",
            SEARCH_METRIC_NAME: round(float(ms), 3),
        }
        print(json.dumps(emf))
    except Exception as exc:  # noqa: BLE001 - metric emission must never raise (R8.3)
        # Swallow and log server-side: a metric failure must not affect the
        # Search_Request. Logged with the module's existing print convention.
        print(f"Failed to emit {SEARCH_METRIC_NAME} metric: {exc!r}")


# --------------------------------------------------------------------------- #
# Structured application logging
#
# A tiny stdlib helper (no third-party dependency, so Lambda packaging is
# unchanged) that emits one single-line JSON record per call. Serialization is
# defensive (default=str) and the whole emit is wrapped so a logging failure can
# never raise and break a request (R4.1, R4.6). Records carry only operational
# fields -- method/resource/status/latency/correlationId and server-side error
# text -- never secrets, raw JWTs, or full customer records (R4.7).
# --------------------------------------------------------------------------- #
def _log(level, message, **fields):
    """Emit one structured, single-line JSON log record (never raises)."""
    try:
        print(json.dumps({"level": level, "message": message, **fields},
                         default=str))
    except Exception:  # noqa: BLE001 - logging must never break a request (R4.6)
        pass


# --------------------------------------------------------------------------- #
# Response helpers
#
# Every response the handler returns is an API Gateway proxy result with a JSON
# body and headers that mark the payload as JSON and non-cacheable (R6.3).
# --------------------------------------------------------------------------- #
def _response(status, body):
    """Build an API Gateway proxy response with a JSON body (R6.3).

    Serializes ``body`` with ``json.dumps`` and sets ``Content-Type:
    application/json`` and ``Cache-Control: no-store`` headers.
    """
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body),
    }


def _error(status, message):
    """Build an error response wrapping ``message`` in a JSON body (R6.3).

    Uses the same proxy-response shape as ``_response`` so error payloads carry
    the same ``Content-Type``/``Cache-Control`` headers.
    """
    return _response(status, {"message": message})


# --------------------------------------------------------------------------- #
# CRUD operations
#
# These functions own the DynamoDB access and the business rules. They let
# DynamoDB/botocore exceptions propagate; the router (task 6.1) maps them to the
# appropriate HTTP status. Invalid client input is raised as ClientInputError.
# --------------------------------------------------------------------------- #
def create_customer(event):
    """Create a Customer_Record from a validated request body (R2.1-R2.3, R2.8).

    Parses and validates the body (at least one of name/email/phone), assigns a
    server-generated UUIDv4 ``customerId``, and stamps ``entity="CUSTOMER"`` plus
    ``createdAt``/``updatedAt`` (ISO-8601 UTC). When an email is present a
    normalized ``emailLower`` is derived and the write becomes a single
    ``TransactWriteItems`` of two conditional ``Put`` operations: the customer
    item and an ``EMAIL#<emailLower>`` guard item, each guarded by
    ``attribute_not_exists(customerId)``. This closes the race window and
    enforces case-insensitive email uniqueness (R2.8, R7.6); the guard-item
    condition failing surfaces (via the router) as a 409. Without an email a
    single conditional ``PutItem`` writes just the customer item (R7.4).

    Returns a 201 response whose body is the created Customer_Record with the
    internal ``emailLower`` and ``entity`` attributes omitted (R2.3).
    """
    data = _parse_body(event)
    attrs = _validate_attributes(data, require_any=True)

    customer_id = str(uuid.uuid4())
    now = _now_iso()

    # Canonical customer item persisted to the Customer_Store.
    item = {
        "customerId": customer_id,
        "entity": "CUSTOMER",
        "createdAt": now,
        "updatedAt": now,
        **attrs,
    }

    table = _get_table()

    if "email" in attrs:
        email_lower = _normalize_email(attrs["email"])
        item["emailLower"] = email_lower
        guard_item = {
            "customerId": f"EMAIL#{email_lower}",
            "entity": "EMAIL",
            "ownerId": customer_id,
        }
        # All-or-nothing: the customer item and its email-guard item are written
        # together. Either Put's condition failing cancels the whole transaction
        # so no partial record is left behind (R7.5).
        _get_client().transact_write_items(
            TransactItems=[
                {
                    "Put": {
                        "TableName": table.name,
                        "Item": _marshal(item),
                        "ConditionExpression": "attribute_not_exists(customerId)",
                    }
                },
                {
                    "Put": {
                        "TableName": table.name,
                        "Item": _marshal(guard_item),
                        "ConditionExpression": "attribute_not_exists(customerId)",
                    }
                },
            ]
        )
    else:
        # No email -> no guard item needed; a single conditional Put guards the
        # (astronomically unlikely) UUID collision (R7.4).
        table.put_item(
            Item=item,
            ConditionExpression=Attr("customerId").not_exists(),
        )

    # Omit internal attributes from the client-visible Customer_Record (R2.3).
    record = {k: v for k, v in item.items() if k not in ("emailLower", "entity")}
    return _response(201, record)


# Internal attributes never exposed in a client-visible Customer_Record.
_INTERNAL_ATTRIBUTES = ("emailLower", "entity")


def _strip_internal(item):
    """Return a copy of a stored item without the internal attributes.

    ``emailLower`` and ``entity`` back the uniqueness guard and item-type
    discrimination; neither belongs in a Customer_Record returned to a client
    (see Data Models in design.md).
    """
    return {k: v for k, v in item.items() if k not in _INTERNAL_ATTRIBUTES}


def get_customer(customer_id):
    """Retrieve a single Customer_Record by Customer_Id (R3.1, R3.2).

    Validates the id up front (R3.3; the router validates the path id too, this
    keeps the operation self-consistent), then performs a ``GetItem``. A miss
    (no ``Item``) returns a 404 (R3.2). On a hit the stored item is returned
    with the internal ``emailLower``/``entity`` attributes stripped and a 200
    status (R3.1, R7.1). Any DynamoDB/botocore error propagates for the router
    to map to 500/503 (R3.6).
    """
    _validate_customer_id(customer_id)

    result = _get_table().get_item(Key={"customerId": customer_id})
    item = result.get("Item")
    if not item:
        return _error(404, "Customer not found.")
    return _response(200, _strip_internal(item))


def list_customers(event):
    """List Customer_Records with opaque-cursor pagination (R3.4, R3.5).

    Scans the Customer_Store filtered to customer items (``entity == "CUSTOMER"``)
    so email-guard items never surface, with the page size resolved by
    ``_page_size`` (default 25, max 100) and the start key decoded from an opaque
    ``cursor``/``next`` query-string parameter via ``_decode_cursor`` (a corrupt
    cursor raises ``ClientInputError`` -> 400). The response body carries
    ``items`` (each with internal attributes stripped) and, when DynamoDB
    returns a ``LastEvaluatedKey``, a ``nextToken`` opaque Pagination_Token for
    the next page (R3.4). An empty Customer_Store yields ``items: []`` with a
    200 status (R3.5). DynamoDB/botocore errors propagate for the router to map
    to 500/503 (R3.6).
    """
    params = event.get("queryStringParameters")
    limit = _page_size(params)

    cursor = None
    if params:
        cursor = params.get("cursor") or params.get("next")
    start_key = _decode_cursor(cursor)

    scan_kwargs = {
        "FilterExpression": Attr("entity").eq("CUSTOMER"),
        "Limit": limit,
    }
    if start_key is not None:
        scan_kwargs["ExclusiveStartKey"] = start_key

    result = _get_table().scan(**scan_kwargs)

    items = [_strip_internal(item) for item in result.get("Items", [])]
    body = {"items": items}

    next_token = _encode_cursor(result.get("LastEvaluatedKey"))
    if next_token is not None:
        body["nextToken"] = next_token

    return _response(200, body)


def search_customers(event):
    """Search Customer_Records by partial, case-insensitive name/email (R2, R3, R4, R5, R7).

    Finds customer items whose ``name`` and/or email contain the supplied
    Search_Term(s) as a case-insensitive substring, returned through the same
    opaque-cursor pagination contract as ``list_customers`` (R4.4, R4.5, R5).

    Processing order (fail-fast, read-only):

    1. ``_validate_search_terms(queryStringParameters)`` runs first so a missing,
       empty, over-length, non-string, or unexpected-key Search_Term is rejected
       with ``ClientInputError`` (-> 400) *before* any Customer_Store read
       (R2.4, R3.4, R4.2, R4.3). It returns the normalized
       ``(name_term_lower, email_term_lower)``.
    2. ``_page_size`` resolves the page size (default 25, max 100) and
       ``_decode_cursor`` decodes the opaque ``cursor``/``next`` Pagination_Token
       into a start key; a corrupt cursor raises ``ClientInputError`` -> 400
       (R5.5, R5.6). ``queryStringParameters`` may be ``None`` (guarded like
       ``list_customers``).
    3. ``_build_search_filter`` builds the DynamoDB ``FilterExpression`` -
       always ``entity == "CUSTOMER"`` (so email-guard items never surface,
       R7.3) and, when an email term is present, an ``emailLower`` contains clause
       applied server-side (which also excludes records without an email, R3.5).
    4. A single paginated ``Scan`` returns a page of candidate items. The
       case-insensitive ``name`` substring match is applied in Python via
       ``_name_matches`` because the stored ``name`` keeps its original casing and
       has no lowercased twin to filter on server-side; records lacking a ``name``
       are thereby excluded (R2.2, R2.5). When no name term was supplied every
       candidate is kept.
    5. Surviving items are stripped of internal attributes (``emailLower`` /
       ``entity``) via ``_strip_internal`` and returned as
       ``_response(200, {items, nextToken?})`` - ``nextToken`` only when the Scan
       returned a ``LastEvaluatedKey`` (R4.5, R5.4).

    This operation performs reads only - never a create/update/delete (R7.2) -
    and a search with no matches returns ``items: []`` with 200 (R2.3, R3.3).
    DynamoDB/botocore exceptions propagate so the router's error map handles them
    (throttling -> 503, other ``ClientError`` -> 500) (R7.4, R7.5).

    Pagination nuance (by design, not a bug): the case-insensitive ``name``
    post-filter runs *after* DynamoDB has already applied the page ``Limit`` to
    the candidate set, so a page can return fewer than ``limit`` items - even
    zero - while still carrying a ``nextToken``. This matches the design's
    "Approach to partial matching": filtered-out candidates still consume the
    page budget, and following the token continues the search until a page
    arrives without a ``LastEvaluatedKey``.
    """
    params = event.get("queryStringParameters")

    # Validate the Search_Terms first so invalid input is rejected before any
    # Customer_Store read (R2.4, R3.4, R4.2, R4.3).
    name_term_lower, email_term_lower = _validate_search_terms(params)

    limit = _page_size(params)

    cursor = None
    if params:
        cursor = params.get("cursor") or params.get("next")
    start_key = _decode_cursor(cursor)

    filter_expression, name_term = _build_search_filter(
        name_term_lower, email_term_lower
    )

    scan_kwargs = {
        "FilterExpression": filter_expression,
        "Limit": limit,
    }
    if start_key is not None:
        scan_kwargs["ExclusiveStartKey"] = start_key

    result = _get_table().scan(**scan_kwargs)

    candidates = result.get("Items", [])
    if name_term is not None:
        # Case-insensitive name post-filter over the page's candidates only; this
        # adds no extra DynamoDB reads (R2.2, R2.5).
        candidates = [c for c in candidates if _name_matches(c, name_term)]

    items = [_strip_internal(item) for item in candidates]
    body = {"items": items}

    next_token = _encode_cursor(result.get("LastEvaluatedKey"))
    if next_token is not None:
        body["nextToken"] = next_token

    return _response(200, body)


def update_customer(event, customer_id):
    """Update an existing Customer_Record, enforcing Unique_Email (R4.1-R4.3, R4.7).

    Validates the path id (R3.3/R5.3-style guard) and the request body (at least
    one of name/email/phone; an attempt to change ``customerId`` is rejected as
    an unexpected field by ``_validate_attributes`` -> R4.6). The current record
    is fetched with ``GetItem`` to read its ``emailLower`` and decide the email
    transition; a miss returns a 404 (R4.3).

    Email unchanged or absent from the request: a single ``UpdateItem`` sets the
    provided attributes plus a fresh ``updatedAt``, guarded by
    ``attribute_exists(customerId)`` so a record deleted in the meantime maps to
    a 404 (the ``ConditionalCheckFailedException`` propagates for the router).

    Email changed: a single all-or-nothing ``TransactWriteItems`` that (1) Puts
    the new ``EMAIL#<newLower>`` guard with ``attribute_not_exists(customerId)``
    (a losing claim cancels the transaction -> 409 via the router), (2) Deletes
    the old ``EMAIL#<oldLower>`` guard when the record had an email, and (3)
    Updates the customer item (set attrs + ``emailLower`` + ``updatedAt``) guarded
    by ``attribute_exists(customerId)`` (-> 404). Because the whole transaction is
    atomic, a losing claim leaves the record and its old email untouched (R4.7).

    Returns a 200 response whose body is the complete updated Customer_Record
    (all fields, not just the changed ones, R4.2) with the internal
    ``emailLower``/``entity`` attributes stripped. DynamoDB/botocore errors
    propagate for the router to map (ConditionalCheckFailed on the guard -> 409,
    on the customer item -> 404, throttling -> 503, other -> 500).
    """
    _validate_customer_id(customer_id)
    data = _parse_body(event)
    attrs = _validate_attributes(data, require_any=True)

    table = _get_table()

    # Fetch the current record to decide the email transition (R4.3/R4.7).
    current = _get_table().get_item(Key={"customerId": customer_id}).get("Item")
    if not current:
        return _error(404, "Customer not found.")

    old_email_lower = current.get("emailLower")
    now = _now_iso()

    new_email_lower = None
    if "email" in attrs:
        new_email_lower = _normalize_email(attrs["email"])

    email_changed = new_email_lower is not None and new_email_lower != old_email_lower

    if not email_changed:
        # Email unchanged or absent: update only the customer item. The provided
        # attributes plus updatedAt are written; attribute_exists guards a
        # concurrent delete (-> 404 via a propagating ConditionalCheckFailed).
        set_attrs = {**attrs, "updatedAt": now}
        expr_names = {}
        expr_values = {}
        set_clauses = []
        for i, (key, value) in enumerate(set_attrs.items()):
            name_placeholder = f"#f{i}"
            value_placeholder = f":v{i}"
            expr_names[name_placeholder] = key
            expr_values[value_placeholder] = value
            set_clauses.append(f"{name_placeholder} = {value_placeholder}")

        result = table.update_item(
            Key={"customerId": customer_id},
            UpdateExpression="SET " + ", ".join(set_clauses),
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_values,
            ConditionExpression=Attr("customerId").exists(),
            ReturnValues="ALL_NEW",
        )
        updated = result["Attributes"]
        return _response(200, _strip_internal(updated))

    # Email changed: build the complete updated item and claim the new email in
    # one atomic transaction (new guard Put, old guard Delete, customer Update).
    updated_item = dict(current)
    updated_item.update(attrs)
    updated_item["emailLower"] = new_email_lower
    updated_item["updatedAt"] = now

    # Customer-item UpdateItem expression: set every provided attr + emailLower +
    # updatedAt. Reserved-word-safe via name placeholders.
    set_pairs = {**attrs, "emailLower": new_email_lower, "updatedAt": now}
    expr_names = {}
    expr_values = {}
    set_clauses = []
    for i, (key, value) in enumerate(set_pairs.items()):
        name_placeholder = f"#f{i}"
        value_placeholder = f":v{i}"
        expr_names[name_placeholder] = key
        expr_values[value_placeholder] = _SERIALIZER.serialize(value)
        set_clauses.append(f"{name_placeholder} = {value_placeholder}")

    guard_item = {
        "customerId": f"EMAIL#{new_email_lower}",
        "entity": "EMAIL",
        "ownerId": customer_id,
    }

    transact_items = [
        {
            "Put": {
                "TableName": table.name,
                "Item": _marshal(guard_item),
                "ConditionExpression": "attribute_not_exists(customerId)",
            }
        },
    ]
    if old_email_lower:
        transact_items.append(
            {
                "Delete": {
                    "TableName": table.name,
                    "Key": _marshal({"customerId": f"EMAIL#{old_email_lower}"}),
                }
            }
        )
    transact_items.append(
        {
            "Update": {
                "TableName": table.name,
                "Key": _marshal({"customerId": customer_id}),
                "UpdateExpression": "SET " + ", ".join(set_clauses),
                "ExpressionAttributeNames": expr_names,
                "ExpressionAttributeValues": expr_values,
                "ConditionExpression": "attribute_exists(customerId)",
            }
        }
    )

    _get_client().transact_write_items(TransactItems=transact_items)

    # Return the complete updated record (R4.2) with internal attrs stripped.
    return _response(200, _strip_internal(updated_item))


def delete_customer(customer_id):
    """Delete a Customer_Record by Customer_Id, cleaning up its email guard (R5.1, R5.2, R7.6).

    Validates the path id up front (R5.3; the router validates it too, this keeps
    the operation self-consistent). The current record is fetched with ``GetItem``
    to read its ``emailLower`` and determine whether an email-guard item must be
    removed alongside it; a miss (no ``Item``) returns a 404 (R5.2).

    When the record carries an ``emailLower``: a single all-or-nothing
    ``TransactWriteItems`` deletes both the customer item - guarded by
    ``attribute_exists(customerId)`` so a concurrent delete surfaces as a
    ``ConditionalCheckFailed`` the router maps to 404 - and its
    ``EMAIL#<emailLower>`` guard item. Deleting both together keeps guard items
    from leaking after their owner is gone (R7.6).

    When the record has no email: a single conditional ``DeleteItem`` on the
    customer item, guarded by ``attribute_exists(customerId)`` so a concurrent
    delete likewise surfaces as a ``ConditionalCheckFailed`` -> 404.

    Returns a 200 response confirming the deletion (R5.1). DynamoDB/botocore
    errors propagate for the router to map (ConditionalCheckFailed -> 404,
    throttling -> 503, other -> 500).
    """
    _validate_customer_id(customer_id)

    table = _get_table()

    # Fetch the current record to confirm existence and read its email, which
    # determines whether a guard item must be removed too (R5.2, R7.6).
    current = table.get_item(Key={"customerId": customer_id}).get("Item")
    if not current:
        return _error(404, "Customer not found.")

    email_lower = current.get("emailLower")

    if email_lower:
        # All-or-nothing: the customer item and its email-guard item are removed
        # together so no orphan guard outlives its owner. attribute_exists guards
        # a concurrent delete (-> 404 via a propagating ConditionalCheckFailed).
        _get_client().transact_write_items(
            TransactItems=[
                {
                    "Delete": {
                        "TableName": table.name,
                        "Key": _marshal({"customerId": customer_id}),
                        "ConditionExpression": "attribute_exists(customerId)",
                    }
                },
                {
                    "Delete": {
                        "TableName": table.name,
                        "Key": _marshal({"customerId": f"EMAIL#{email_lower}"}),
                    }
                },
            ]
        )
    else:
        # No email -> no guard item; a single conditional DeleteItem removes the
        # customer item. attribute_exists surfaces a concurrent delete as a
        # ConditionalCheckFailed the router maps to 404.
        table.delete_item(
            Key={"customerId": customer_id},
            ConditionExpression=Attr("customerId").exists(),
        )

    return _response(200, {"message": "Customer deleted.", "customerId": customer_id})


# --------------------------------------------------------------------------- #
# Router and centralized error mapping
#
# A single ``lambda_handler`` dispatches on the API Gateway proxy event's
# ``httpMethod`` + ``resource`` to one of the five CRUD operations and wraps the
# dispatch in one try/except that maps every failure to the right HTTP status,
# per the "Error Handling" table in design.md. External/data-store failures are
# logged in full server-side and returned to the client as a generic message
# with no partial Customer_Record data (R3.6, R6.4, R7.5).
# --------------------------------------------------------------------------- #

# DynamoDB error codes that indicate transient throttling; mapped to 503 so the
# client can retry rather than treating it as a hard server fault.
_THROTTLING_CODES = frozenset(
    {
        "ThrottlingException",
        "ProvisionedThroughputExceededException",
        "RequestLimitExceeded",
    }
)

# Generic server-side error message. The full exception is logged server-side;
# the client only ever sees this so no internal/partial detail leaks (R6.4,
# R7.5).
_GENERIC_ERROR_MESSAGE = "The request could not be completed."


def _path_id(event):
    """Extract the ``{id}`` path parameter from an API Gateway proxy event.

    Returns the raw value (or ``None`` when absent) so the operation's own
    ``_validate_customer_id`` can reject an empty/oversized id with a 400.
    """
    params = event.get("pathParameters") or {}
    return params.get("id")


def _transaction_conflict_status(method, error):
    """Map a ``TransactionCanceledException`` to 409 or 404 for the given method.

    ``TransactWriteItems`` failures arrive as a ``TransactionCanceledException``
    whose ``CancellationReasons`` list has one entry per transact item, in the
    same order the operation built them. A ``ConditionalCheckFailed`` reason is
    the signal; which item failed decides the status (per the design's note):

    - **create** (POST): the transaction is ``[customer Put, guard Put]``. The
      customer item uses a freshly generated UUID, so its
      ``attribute_not_exists`` condition effectively always passes; a cancelled
      create therefore means the email-guard claim failed -> 409 (email in use).

    - **update** (PUT): the transaction is ``[guard Put, (optional old-guard
      Delete), customer Update]``. Index 0 is the new email-guard
      (``attribute_not_exists``); if its reason is ``ConditionalCheckFailed`` the
      email is already in use -> 409. Otherwise the failure is on the customer
      item (``attribute_exists``) -> the record is gone -> 404.

    - **delete** (DELETE): the transaction is ``[customer Delete, guard
      Delete]``. Index 0 is the customer item (``attribute_exists``); a
      ``ConditionalCheckFailed`` there means the record no longer exists -> 404.

    Falls back to 409 for create and 404 for update/delete when the reasons are
    unavailable, matching each operation's dominant conflict mode.
    """
    reasons = error.response.get("CancellationReasons") or []

    def failed(index):
        return (
            index < len(reasons)
            and reasons[index].get("Code") == "ConditionalCheckFailed"
        )

    if method == "POST":
        # Only the guard-item claim can realistically fail -> email in use.
        return 409
    if method == "PUT":
        # Guard Put is first; its failure means the email is already claimed.
        return 409 if failed(0) else 404
    # DELETE (and any other transactional write): the customer-item condition
    # is first; its failure means the record is already gone.
    return 404


def lambda_handler(event, context):
    """API Gateway proxy entry point: route the request and map errors (R6).

    Dispatches on ``httpMethod`` + ``resource`` to the CRUD operations plus
    search:

        GET    /customers         -> list_customers(event)
        GET    /customers/search  -> search_customers(event)
        GET    /customers/{id}    -> get_customer(id)
        POST   /customers         -> create_customer(event)
        PUT    /customers/{id}    -> update_customer(event, id)
        DELETE /customers/{id}    -> delete_customer(id)

    The literal ``/customers/search`` resource is matched by its own branch,
    independently of ``/customers`` and ``/customers/{id}``. That branch is timed
    with ``time.perf_counter()`` and emits the ``SearchLatencyMs`` metric via
    ``_emit_search_latency`` in a ``finally`` so latency is recorded on both the
    success and the error path, while any exception still propagates to the
    centralized error map below (R8.1).

    An undefined method/resource combination returns 405 (R6.6 is primarily the
    API Gateway's job; this is a defensive backstop). The whole dispatch is
    wrapped in one try/except implementing the design's Error Handling table:
    ``ClientInputError`` -> 400; a ``TransactionCanceledException`` guard/customer
    conflict -> 409/404; a non-transactional ``ConditionalCheckFailedException``
    -> 404; DynamoDB throttling -> 503; any other ``ClientError`` -> 500 (logged
    in full server-side, generic message to the client); any other exception ->
    500. Every response carries ``Content-Type: application/json`` and
    ``Cache-Control: no-store`` via ``_response``/``_error``.
    """
    method = event.get("httpMethod")
    resource = event.get("resource")
    # Correlation_Id ties this request's Structured_Logs to the matching API
    # Gateway access-log entry and X-Ray trace: prefer the API Gateway request
    # id, fall back to the Lambda request id (R4.2).
    correlation_id = (
        (event.get("requestContext") or {}).get("requestId")
        or getattr(context, "aws_request_id", None)
    )
    start = time.perf_counter()

    def _dispatch():
        """Route the request and map errors to a response (behavior unchanged)."""
        try:
            if resource == "/customers":
                if method == "GET":
                    return list_customers(event)
                if method == "POST":
                    return create_customer(event)
            elif resource == "/customers/search":
                # The literal `search` path is matched on its own, ahead of the
                # `{id}` branch. The search branch is instrumented: time it with
                # perf_counter and emit SearchLatencyMs in a finally so latency
                # is recorded on both the success and error path (R8.1). The
                # inner try/finally sits inside this try/except, so any exception
                # raised by search_customers still propagates to the centralized
                # error map after the metric is emitted; _emit_search_latency is
                # best-effort and never raises.
                if method == "GET":
                    search_start = time.perf_counter()
                    try:
                        return search_customers(event)
                    finally:
                        _emit_search_latency(
                            (time.perf_counter() - search_start) * 1000.0
                        )
            elif resource == "/customers/{id}":
                if method == "GET":
                    return get_customer(_path_id(event))
                if method == "PUT":
                    return update_customer(event, _path_id(event))
                if method == "DELETE":
                    return delete_customer(_path_id(event))

            # No route matched the method/resource pair.
            return _error(405, "Method not allowed.")

        except ClientInputError as exc:
            # Invalid client input -> 400 with the specific, client-safe message.
            return _error(400, str(exc))

        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code")

            if code == "TransactionCanceledException":
                # A guard/customer conditional failure inside a transaction.
                status = _transaction_conflict_status(method, exc)
                if status == 409:
                    return _error(409, "Email is already in use.")
                return _error(404, "Customer not found.")

            if code == "ConditionalCheckFailedException":
                # A non-transactional UpdateItem/DeleteItem condition failed,
                # meaning the targeted Customer_Record no longer exists.
                return _error(404, "Customer not found.")

            if code in _THROTTLING_CODES:
                # Transient throttling -> ask the client to retry.
                return _error(503, "The service is temporarily unavailable.")

            # Any other data-store error: log the full exception server-side and
            # return a generic message with no partial Customer_Record
            # (R3.6, R7.5).
            _log(
                "ERROR",
                "datastore_error",
                method=method,
                resource=resource,
                correlationId=correlation_id,
                error=repr(exc),
            )
            return _error(500, _GENERIC_ERROR_MESSAGE)

        except Exception as exc:  # noqa: BLE001 - final backstop (R6.4)
            # Any unexpected error -> log in full and return a generic 500.
            _log(
                "ERROR",
                "unexpected_error",
                method=method,
                resource=resource,
                correlationId=correlation_id,
                error=repr(exc),
            )
            return _error(500, _GENERIC_ERROR_MESSAGE)

    # Run the dispatch, then emit exactly one request-scoped Structured_Log with
    # the actual returned status and server-side latency, on both the success
    # and the error path (R4.1, R4.2, R4.3). Client responses are unchanged.
    response = _dispatch()
    _log(
        "INFO",
        "request_completed",
        method=method,
        resource=resource,
        status=response.get("statusCode"),
        latencyMs=round((time.perf_counter() - start) * 1000.0, 3),
        correlationId=correlation_id,
    )
    return response

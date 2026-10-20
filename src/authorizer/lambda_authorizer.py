# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Lambda Authorizer for the Customer Management Platform.

Validates the JWT presented on each API Gateway request (issued by the Cognito
Identity_Provider) before the request reaches the Users_API, and returns an IAM
policy allowing or denying access.

The token-validation and policy-generation logic is implemented in a later task
(handler ``lambda_handler``); this module currently establishes the file and its
copyright header as part of the project scaffold.
"""
import json
import os

import jwt

# Region is provided by the Lambda runtime and is never hardcoded; the issuer
# URL is built from it so the authorizer works in whatever Region it is deployed.
REGION = os.environ['AWS_REGION']
USER_POOL_ID = os.environ['USER_POOL_ID']
APPLICATION_CLIENT_ID = os.environ['APPLICATION_CLIENT_ID']
ADMIN_GROUP_NAME = os.environ.get('ADMIN_GROUP_NAME', 'Administrators')
ISSUER = f'https://cognito-idp.{REGION}.amazonaws.com/{USER_POOL_ID}'

# Created once per execution environment, so the user pool's signing keys are
# fetched from the JWKS endpoint on the first request and reused by later ones.
jwks_client = jwt.PyJWKClient(f'{ISSUER}/.well-known/jwks.json')


def _log(level, message, **fields):
    """Emit one structured, single-line JSON log record (never raises).

    Mirrors the users Lambda's logger. Records only the server-side failure
    reason and operational fields -- never the token, JWT claim values, or
    secrets (R4.5, R4.7).
    """
    try:
        print(json.dumps({'level': level, 'message': message, **fields},
                         default=str))
    except Exception:  # noqa: BLE001 - logging must never break authorization
        pass


def lambda_handler(event, context):
    """Validate the request's JWT and return an API Gateway IAM policy.

    On success returns a stage-wide Allow policy with a ``context`` block
    (``userId``, ``email``, ``isAdmin``). On any failure -- a missing, malformed,
    expired, or wrong-issuer token, or an unreachable Identity_Provider (JWKS) --
    raises ``Exception('Unauthorized')`` so API Gateway answers HTTP 401.
    """
    token = event.get('authorizationToken', '').replace('Bearer ', '', 1)

    try:
        # Resolve the signing key from the user pool's JWKS, then verify the
        # RS256 signature, the issuer claim, and expiry (60s leeway).
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=['RS256'],
            issuer=ISSUER,
            leeway=60,
            options={'verify_aud': False},  # checked below: access tokens have no 'aud'
        )

        # ID tokens name the app client in 'aud', access tokens in 'client_id'.
        if claims.get('token_use') not in ('id', 'access'):
            raise ValueError('Invalid token use')
        if claims.get('aud', claims.get('client_id')) != APPLICATION_CLIENT_ID:
            raise ValueError('Invalid audience')
    except Exception as e:
        _log('ERROR', 'authorization_failed', reason=str(e))
        raise Exception('Unauthorized')  # API Gateway answers 401

    # API Gateway caches this policy per token, so allow every method of the
    # stage. A policy for event['methodArn'] alone would block the token's next
    # call to a different method.
    api_stage_arn = '/'.join(event['methodArn'].split('/')[:2])
    groups = claims.get('cognito:groups', [])

    return {
        'principalId': claims['sub'],
        'policyDocument': {
            'Version': '2012-10-17',
            'Statement': [
                {
                    'Action': 'execute-api:Invoke',
                    'Effect': 'Allow',
                    'Resource': f'{api_stage_arn}/*/*',
                }
            ],
        },
        'context': {
            'userId': claims['sub'],
            'email': claims.get('email', ''),
            'isAdmin': str(ADMIN_GROUP_NAME in groups).lower(),
        },
    }

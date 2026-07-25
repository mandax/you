# Management REST API

> See also [authkit.md](authkit.md) for the login flows and
> [integration.md](integration.md) for OIDC/JWT details.

The management API lets you automate You from any service that can speak HTTP:
provision users, register apps, revoke sessions, and read the recent audit
stream — no console login required.

## Base URL and authentication

All endpoints live under `/api/v1` and require a bearer token:

```
Authorization: Bearer <API_TOKEN>
```

The token is configured with the `API_TOKEN` environment variable
(`config :you, :api_token`). If it is unset or empty the API is disabled and
every request returns `403 {"error": "management_api_disabled"}`. Comparisons
are constant-time. The API is rate-limited per client IP (default: 120
requests per minute); on excess you get `429 {"error": "rate_limited"}` with a
`Retry-After` header.

All errors share one shape, with the right status code:

```json
{"error": "invalid_token"}
```

Validation failures add a `details` map of field errors:

```json
{"error": "validation_failed", "details": {"email": ["has already been taken"]}}
```

| Status | Meaning |
|--------|---------|
| `401`  | Missing or wrong bearer token (`invalid_token`) |
| `403`  | API disabled — no token configured (`management_api_disabled`) |
| `404`  | Unknown id (`not_found`) |
| `422`  | Invalid payload (`validation_failed` + `details`) |
| `429`  | Rate limited (`rate_limited`) |

## Users

### List users

```sh
curl -H "Authorization: Bearer $API_TOKEN" https://you.example.com/api/v1/users
```

```json
{
  "data": [
    {
      "id": 1,
      "email": "alice@example.com",
      "is_admin": true,
      "confirmed": true,
      "inserted_at": "2026-07-25T10:00:00"
    }
  ]
}
```

Password hashes and other secrets are never included.

### Get one user

```sh
curl -H "Authorization: Bearer $API_TOKEN" https://you.example.com/api/v1/users/1
```

Same shape as a list entry, under `data`. Unknown ids return `404`.

### Create a user

```sh
curl -X POST -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email": "bob@example.com", "password": "correct horse battery"}' \
  https://you.example.com/api/v1/users
```

`201` with the created user under `data`. The account is confirmed
immediately and the password works right away — no magic-link round-trip.
Invalid input (bad email, short password, duplicate email) returns `422` with
field errors.

### Revoke all sessions

```sh
curl -X POST -H "Authorization: Bearer $API_TOKEN" \
  https://you.example.com/api/v1/users/1/logout
```

Deletes every token for the user — sessions, magic links, resets. `200` with
the user under `data`.

### Delete a user (anonymize)

```sh
curl -X DELETE -H "Authorization: Bearer $API_TOKEN" \
  https://you.example.com/api/v1/users/1
```

Users are never hard-deleted (LGPD). The email is replaced with a random
`redacted-…@anonymized.you` address and all credentials, tokens, and consents
are wiped. `200` with the anonymized user under `data`.

## Apps

### List apps

```sh
curl -H "Authorization: Bearer $API_TOKEN" https://you.example.com/api/v1/apps
```

```json
{
  "data": [
    {
      "id": 1,
      "slug": "my-app",
      "name": "My App",
      "callback_url": "https://app.example.com/cb",
      "launch_url": null,
      "first_party": false,
      "inserted_at": "2026-07-25T10:00:00",
      "updated_at": "2026-07-25T10:00:00"
    }
  ]
}
```

The client secret hash is never included.

### Create an app

```sh
curl -X POST -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"slug": "my-app", "name": "My App", "callback_url": "https://app.example.com/cb"}' \
  https://you.example.com/api/v1/apps
```

`201` with the app under `data`, plus a one-time `client_secret`:

```json
{
  "data": {
    "id": 1,
    "slug": "my-app",
    "client_secret": "Xb9…",
    "…": "…"
  }
}
```

This is the only time the secret is shown — store it now. Required fields:
`slug`, `name`, `callback_url`. Optional: `launch_url`, `first_party`.

### Update an app

```sh
curl -X PATCH -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Renamed", "first_party": true}' \
  https://you.example.com/api/v1/apps/1
```

Updatable fields: `name`, `callback_url`, `launch_url`, `first_party`.
`200` with the updated app under `data`.

### Delete an app

```sh
curl -X DELETE -H "Authorization: Bearer $API_TOKEN" \
  https://you.example.com/api/v1/apps/1
```

`204` with an empty body.

### Assign a user's role in an app

```sh
curl -X PUT -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"role": "admin"}' \
  https://you.example.com/api/v1/apps/1/roles/42
```

Roles are per-app and must be one of the app's `allowed_roles` (default
`["user", "admin"]`); tokens issued for that app carry the role in their
claims. `200` with `{"data": {"user_id": 42, "role": "admin"}}`,
`422 invalid_role` for a role the app does not allow, `404` for unknown
app or user.

### Reset a user's role

```sh
curl -X DELETE -H "Authorization: Bearer $API_TOKEN" \
  https://you.example.com/api/v1/apps/1/roles/42
```

Removes the assignment (back to the implicit `"user"` role). `204` with an
empty body.

## Audit

```sh
curl -H "Authorization: Bearer $API_TOKEN" https://you.example.com/api/v1/audit
```

```json
{
  "data": [
    {
      "event": "admin:action",
      "measurements": {},
      "metadata": {"action": "update_app", "app_slug": "my-app"},
      "at": "2026-07-25T10:05:00Z"
    }
  ]
}
```

Newest first, capped at 100 events. This is the live in-memory activity view,
not a durable log — for retention, configure the audit webhook.

## Which API should I use?

Use the **management API** (this document) when you operate You itself:
provisioning users and apps, forcing logouts, watching the audit stream from
your own automation. Use **SCIM** (`/scim/v2`) when an external identity
system (an IdP or HR tool) needs to push and sync user lifecycle into You
using the standard protocol. Use **You.SDK** when you're building an app on
the BEAM and want to consume You as an identity provider over Erlang
distribution — login flows, token exchange, userinfo — not to administer You.

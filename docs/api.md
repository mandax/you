# Management REST API

> See also [authkit.md](authkit.md) for the login flows and
> [integration.md](integration.md) for OIDC/JWT details.

The management API lets you automate You from any service that can speak HTTP:
provision users, register apps, revoke sessions, and read the recent audit
stream. No console login required.

## Base URL and authentication

All endpoints live under `/api/v1` and require a bearer token:

```
Authorization: Bearer <API_TOKEN>
```

The token is the `api_token` instance setting: `API_TOKEN` seeds it on first
boot, and the console owns it after that, so rotating it takes effect on the
next request without a restart. If it is unset or blank the API is disabled and
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
| `403`  | API disabled, no token configured (`management_api_disabled`) |
| `404`  | Unknown id (`not_found`) |
| `422`  | Invalid payload (`validation_failed` + `details`) |
| `429`  | Rate limited (`rate_limited`) |

## Users

### List users

```sh
curl -H "Authorization: Bearer $API_TOKEN" \
  "https://you.example.com/api/v1/users?limit=100&offset=0"
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
  ],
  "meta": {"limit": 100, "offset": 0, "total": 4213}
}
```

Password hashes and other secrets are never included.

**The response is paged, whether or not you ask.** `limit` defaults to 100 and
is capped at 500; `offset` defaults to 0. Read `meta.total` and walk `offset`
to enumerate every account — a client that reads `data` alone and stops will
silently see only the first page.

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
immediately and the password works right away, with no magic-link round-trip.
Invalid input (bad email, short password, duplicate email) returns `422` with
field errors.

### Revoke all sessions

```sh
curl -X POST -H "Authorization: Bearer $API_TOKEN" \
  https://you.example.com/api/v1/users/1/logout
```

Deletes every token for the user: sessions, magic links, resets. `200` with
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
      "jwt_expiry_hours": null,
      "code_expiry_minutes": null,
      "custom_claims": {},
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

This is the only time the secret is shown, so store it now. Required fields:
`slug`, `name`, `callback_url`. Optional: `launch_url`, `first_party`,
`jwt_expiry_hours`, `code_expiry_minutes`, `custom_claims`.

### Update an app

```sh
curl -X PATCH -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Renamed", "first_party": true}' \
  https://you.example.com/api/v1/apps/1
```

Updatable fields: `name`, `callback_url`, `launch_url`, `first_party`,
`jwt_expiry_hours`, `code_expiry_minutes`, `custom_claims`. `200` with the
updated app under `data`.

`jwt_expiry_hours` and `code_expiry_minutes` are per-app overrides: `null`
means the app follows the instance setting, which is the default and what
every app does until it is given its own. A token lifetime is an app's
decision — an internal admin tool and a public mobile client should not share
one expiry. Bounded at 720 hours and 60 minutes respectively; a lifetime is a
security control, and a fat-fingered `8760` is a token that outlives the
employment it was issued during.

Session expiry stays instance-wide. That is the You portal cookie, one per
browser across every app, so it has no app to belong to.

`custom_claims` is a JSON object of static claims merged into every JWT
issued for the app — its tenant id, plan, or feature flags, so the app reads
them from the token instead of making a second round-trip:

```sh
curl -X PATCH -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"custom_claims": {"tenant_id": "acme", "plan": "pro", "seats": 25}}' \
  https://you.example.com/api/v1/apps/1
```

They can only add. The claims You issues — `sub`, `app`, `email`, `name`,
`role`, and the registered JWT claims — are refused here and applied on top
regardless, so an app can never rewrite the identity or the role a consumer
authorizes on, or the expiry that makes its token expire.

Values may be strings, numbers, booleans, or lists of those. Nesting is
refused: a token is a place for facts a consumer gates on, and anything
wanting a shape belongs behind userinfo. At most 32 claims and 1024 bytes of
JSON — a JWT travels in an `Authorization` header, and header limits at the
edge are not yours to raise.

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
not a durable log. For retention, configure the audit webhook.

## Configuration bundles

A bundle is this instance's settings, apps, identity providers, webhook
endpoints and email templates, sealed under a password you choose.
Configuration, not data: no users, tokens, sessions or consents. Note that
email templates carry operator-authored copy — check what yours say before
handing an export to anyone outside your organisation. Instance identity — `erlang_cookie`,
`api_token`, `scim_bearer_token` — is refused in both directions, so a
restore never clones another instance's credentials.

Every action is a POST, export included: the password would otherwise land in
access logs and browser history as a query string.

### Export

```sh
curl -X POST -H "Authorization: Bearer $API_TOKEN" \
  -H "content-type: application/json" \
  -d "{\"password\": \"$BUNDLE_PASSWORD\"}" \
  https://you.example.com/api/v1/config/bundle > config.you-bundle
```

Responds with the sealed envelope as `application/octet-stream` — the same
bytes the console's download button produces. The password must be at least
12 characters (`422 password_too_short` otherwise).

### Preview

```sh
jq -n --arg p "$BUNDLE_PASSWORD" --rawfile b config.you-bundle \
  '{password: $p, bundle: $b}' |
  curl -X POST -H "Authorization: Bearer $API_TOKEN" \
    -H "content-type: application/json" --data-binary @- \
    https://you.example.com/api/v1/config/bundle/preview
```

Reports what an import would change — which settings differ, which apps and
providers are created or updated, and which instance-identity keys were
present and will be ignored — without writing anything. A wrong password is
`401 wrong_password`; a file that is not a bundle is `422 malformed`.

### Import

Same body, `POST /api/v1/config/bundle/import`. Upserts by natural key
(settings by key, apps by slug, providers by slug, webhooks by url) and never
deletes: an instance that has diverged keeps whatever the bundle does not
mention. Applied in one transaction.

### From the command line

Disaster recovery is exactly when the console — and possibly the HTTP
endpoint — may be the thing that is unavailable. The same three operations run
locally:

```sh
mix you.bundle export config.you-bundle [--force]
mix you.bundle preview config.you-bundle
mix you.bundle import config.you-bundle
```

In a release, where Mix is not installed:

```sh
bin/you eval 'You.Release.export_bundle("/data/you/config.you-bundle")'
bin/you eval 'You.Release.preview_bundle("/data/you/config.you-bundle")'
bin/you eval 'You.Release.import_bundle("/data/you/config.you-bundle")'
```

The password is read from `YOU_BUNDLE_PASSWORD_FILE` (the file's contents),
then `YOU_BUNDLE_PASSWORD`, then an interactive prompt. There is deliberately
no `--password` flag: a password on a command line lands in shell history, in
`ps` output, and in CI logs. For CI, mount a secret and point
`YOU_BUNDLE_PASSWORD_FILE` at it.

## Which API should I use?

Use the **management API** (this document) when you operate You itself:
provisioning users and apps, forcing logouts, watching the audit stream from
your own automation. Use **SCIM** (`/scim/v2`) when an external identity
system (an IdP or HR tool) needs to push and sync user lifecycle into You
using the standard protocol. Use **You.SDK** when you're building an app on
the BEAM and want to consume You as an identity provider over Erlang
distribution (login flows, token exchange, userinfo), not to administer You.

# AuthKit — Integrating with You

> See also [integration.md](integration.md) for the OIDC endpoints, JWKS
> verification, and the Erlang distribution path.

You is the identity provider. An app integrates in one of two ways: the **redirect
(OAuth) flow** (works for any app, including third-party) or the **headless
(invisible) flow** (trusted first-party apps only). Signed-in users can manage
their connected apps at the account hub.

---

## 1. Redirect / OAuth flow

Any registered app can use this flow. The browser mediates every step — You owns
the login page, the consent screen, and the redirect back to the app.

### 1.1 Start the flow

Redirect the user's browser to You's login page with these query parameters:

```
GET /users/log-in
  ?callback_url=https://app.example.com/oauth/callback
  &scope=email profile
  &state=random-opaque-string
  &code_challenge=base64url(sha256(code_verifier))
  &code_challenge_method=S256
```

| Param                 | Notes |
|-----------------------|-------|
| `callback_url`        | Must match the registered callback URL of one of your apps (exact match — prevents open redirects). |
| `scope`               | Space-separated. Supported: `email`, `profile`, `roles`. Defaults to `email`. |
| `state`               | Opaque value echoed back to your callback; use for CSRF / routing. |
| `code_challenge`      | PKCE code challenge (S256). |
| `code_challenge_method` | Must be `S256`. |

> PKCE (S256) is supported and advertised at `/.well-known/openid-configuration`.
> The plain method is not supported; failing to send a challenge results in a
> non-PKCE code that still works but with weaker security.

### 1.2 User authenticates

The user lands on You's login page (branded with your app's name — You resolves
it from the callback URL). They authenticate with any supported method:

- **Password** (with optional TOTP second factor),
- **Magic link** (sent to their email),
- **Passkey** (WebAuthn),
- **Social login** — "Sign in with Google / GitHub / …" (see section 4).

After authenticating, the user sees a consent screen listing the scopes your app
requested. They approve it, and You redirects back to your `callback_url`:

```
GET https://app.example.com/oauth/callback?code=ya29.xxx&state=random-opaque-string
```

Verify `state` matches the value you sent. Then exchange `code` for tokens.

### 1.3 Exchange the code

You offers two code-exchange paths — pick the one that fits your stack.

#### Via Erlang distribution

Add `:you_sdk` as a dependency and connect to You's Erlang node. Then:

```elixir
You.SDK.exchange_code(code, code_verifier: verifier)
# => {:ok, %{user_id: 1, email: "alice@example.com", jwt: "eyJ..."}}
# => {:error, :invalid_grant}   # expired code or PKCE mismatch
# => {:error, :unreachable}     # node not reachable
```

Configure the node in your app's config:

```elixir
config :you_sdk, node: :"you@you.example.com"
```

#### Via HTTP

`POST /oauth/token` with a JSON body:

```http
POST /oauth/token
Content-Type: application/json

{
  "code": "ya29.xxx",
  "code_verifier": "the-raw-pkce-verifier"
}
```

Success response (`200`):

```json
{
  "access_token": "eyJ...",
  "token_type": "Bearer",
  "expires_in": 86400,
  "refresh_token": "rt_..."
}
```

Error response (`400`):

```json
{
  "error": "invalid_grant",
  "error_description": "The authorization code is invalid or has expired."
}
```

No client authentication is required at the token endpoint (it's a public client
flow — the PKCE verifier authenticates the code holder).

### 1.4 OIDC discovery

You exposes standard OpenID Connect discovery at:

```
GET /.well-known/openid-configuration
```

This advertises the authorization endpoint, token endpoint, JWKS URI, supported
scopes, PKCE support (`S256`), and the EdDSA signing algorithm. JWT verification
keys are at:

```
GET /.well-known/jwks.json
```

---

## 2. Headless / invisible flow (first-party only)

Trusted apps that **own their login UI** can authenticate users directly against
You's API — no redirect, no You-branded page. The user never knows You is involved.

**Security model:**

- Only apps flagged **first-party** in the console may use this flow.
- The app authenticates itself with its `client_id` + `client_secret`.
- MFA is enforced: if the user has TOTP enabled, the first call returns
  `mfa_required`; the app must re-call with a valid `totp_code`.
- Third-party apps **must** use the redirect flow.

### 2.1 Via Erlang distribution

```elixir
You.SDK.password_login(client_id, client_secret, %{
  email: "alice@example.com",
  password: "s3cret",
  scopes: ["email", "profile"],
  totp_code: "123456"         # optional unless MFA is required
})
# => {:ok, %{user_id: 1, email: "alice@example.com", jwt: "eyJ...", refresh_token: "rt_..."}}
# => {:error, :invalid_client}
# => {:error, :not_first_party}
# => {:error, :invalid_credentials}
# => {:error, :mfa_required}
# => {:error, :invalid_mfa}
```

### 2.2 Via HTTP

```
POST /api/auth/login
```

**Client authentication** (choose one):

- **HTTP Basic:** `Authorization: Basic base64(client_id:client_secret)`
- **Body params:** `client_id` + `client_secret` in the JSON body (fallback if no
  Basic header is present).

**Body parameters:**

```json
{
  "email": "alice@example.com",
  "password": "s3cret",
  "scope": "email profile",
  "totp_code": "123456"
}
```

| Field        | Notes |
|--------------|-------|
| `email`      | Required. |
| `password`   | Required. |
| `scope`      | Space-separated scopes. Defaults to `email`. |
| `totp_code`  | Required only if the user has TOTP MFA enabled. |

**Success response** (`200`):

```json
{
  "access_token": "eyJ...",
  "token_type": "Bearer",
  "refresh_token": "rt_...",
  "user": {
    "id": 1,
    "email": "alice@example.com"
  }
}
```

**Error responses:**

| Reason | HTTP status | Body |
|--------|-------------|------|
| `:invalid_client` | `401` | `{"error": "invalid_client"}` |
| `:not_first_party` | `403` | `{"error": "unauthorized_client", "error_description": "This client may not use the headless password grant."}` |
| `:invalid_credentials` | `401` | `{"error": "invalid_credentials"}` |
| `:mfa_required` | `401` | `{"error": "mfa_required", "error_description": "A TOTP code is required."}` |
| `:invalid_mfa` | `401` | `{"error": "invalid_mfa", "error_description": "The TOTP code is invalid."}` |

On `mfa_required`, re-submit the same request with the user's TOTP code in
`totp_code`. On `invalid_mfa`, let the user retry.

---

## 3. Making an app first-party

An app must be flagged first-party before it can use the headless flow. In the
admin console at `/console?view=apps`:

1. Find your app in the table and click **Edit**.
2. Tick the **First-party app** checkbox.
3. (Optional) Set a **Launch URL** — this is the destination when a user clicks
   the app's card on the account hub dashboard.
4. Click **Save**.

The flag and the client secret together gate the headless flow. A third-party
app (first-party unchecked) calling `POST /api/auth/login` gets a `403`.

---

## 4. The account hub

Signed-in users land at `/users/dashboard`. This page shows a grid of app cards —
one for every app the user has previously granted consent to (via the redirect
flow). Each card:

- **Opens the app** at its launch URL (or the origin of its callback URL).
  Because the user is already signed into You, the app can immediately start an
  OAuth flow and the user skips the login step (single sign-on).
- **Has a revoke button** (hover to reveal). Revoking deletes the consent row;
  the app must re-authorise to access the user's data again.

> The account hub is **optional**. In the headless flow, the user never needs to
> visit You at all — the app owns the entire experience.

---

## 5. Social login

"Sign in with Google" (or any configured upstream OIDC provider) works in both
flows:

- **Redirect flow:** If the user clicks a social provider on You's login page,
  they are redirected to the upstream IdP, authenticate there, and come back to
  You. You completes the login by handing an authorization code back to the
  requesting app — exactly like password or magic-link login. The app never
  deals with the upstream provider directly.

- **Plain login:** If there is no OAuth consumer in play (the user went directly
  to `/users/log-in`), the social login signs them into You itself.

**Takeover protection:** When a social identity is presented, You only
auto-links it to an existing account if the upstream IdP reports the user's
email as **verified** (`email_verified` claim is `true` or `"true"`). If the
email isn't verified, You refuses the link and tells the user to sign in with
their existing method first, then link the provider from account settings. This
prevents an attacker from hijacking an account by creating a social identity
with a matching-but-unverified email address.

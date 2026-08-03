# Integrating an App with You

You is an OpenID Connect identity provider. Any app that can do an HTTP
redirect and verify a JWT can integrate: no Elixir or Erlang required. Apps
running on the BEAM (Elixir/Erlang) have a second, lower-latency option:
`You.SDK` over Erlang distribution.

The OIDC path is the standard, recommended integration. Use the SDK only for
trusted first-party services inside your own cluster.

---

## 1. OIDC (standard, any language)

### 1.1 Discovery

You publishes a standard discovery document:

```
GET /.well-known/openid-configuration
```

It advertises the authorization endpoint (`/users/log-in`), the token endpoint
(`/oauth/token`), the JWKS URI (`/.well-known/jwks.json`), supported scopes
(`email`, `profile`, `roles`), PKCE (`S256`), and the signing algorithm
(`EdDSA`, Ed25519).

### 1.2 Authorization (authorization_code + PKCE)

Register your app in the You console, then redirect the user's browser:

```
GET /users/log-in
  ?callback_url=https://app.example.com/oauth/callback
  &scope=email profile
  &state=<random-opaque-string>
  &code_challenge=base64url(sha256(code_verifier))
  &code_challenge_method=S256
```

- `callback_url` must exactly match a callback URL registered for your app.
- `state` is echoed back; verify it on the callback (CSRF protection).
- Always send a PKCE challenge; only `S256` is supported.

The user authenticates on You (password, magic link, passkey, or social
login), approves the consent screen, and You redirects back:

```
GET https://app.example.com/oauth/callback?code=ya29.xxx&state=<same-state>
```

The code is single-use and expires after 5 minutes.

### 1.3 Token exchange

```
POST /oauth/token
Content-Type: application/json

{
  "code": "ya29.xxx",
  "code_verifier": "<the-raw-pkce-verifier>"
}
```

Success (`200`):

```json
{
  "access_token": "eyJ...",
  "token_type": "Bearer",
  "expires_in": 86400,
  "refresh_token": "rt_..."
}
```

Failure (`400`): `{"error": "invalid_grant", "error_description": "..."}`.

#### Client authentication is required

Every code exchange must prove the caller is the client the code was issued
to. There are two accepted proofs, and a request carrying neither is rejected
with `401 {"error": "invalid_client"}`:

- **Public clients** (SPA, mobile) send the PKCE `code_verifier`, as above. The
  code must have been minted from an authorize request carrying a
  `code_challenge`.
- **Confidential clients** (server-side apps) send `client_id` +
  `client_secret`, either as HTTP Basic (RFC 6749 §2.3.1) or in the body:

  ```http
  POST /oauth/token
  Authorization: Basic base64(client_id:client_secret)
  Content-Type: application/json

  {"code": "ya29.xxx"}
  ```

A code minted **without** a PKCE challenge can only be redeemed with the client
secret. A code minted for one app cannot be redeemed by another: a mismatched
`client_id` fails with `invalid_grant`.

The **refresh_token grant** is also supported: POST the `refresh_token` to
`/oauth/token` to obtain a new access token without involving the user. Client
credentials are optional there, but when sent they must be valid and must match
the app the refresh token was issued for.

### 1.4 Verifying the JWT locally, with no call to You

The access token is a JWT signed with **EdDSA (Ed25519)**. You's public key is
published at `/.well-known/jwks.json`. Verification is entirely local: fetch
the JWKS once, cache it, and verify signatures in your app. **You is not
involved per request.**

Claims in the token: `sub` (user id), `app` (`"you"`), `jti`, `iat`, `exp`,
plus the scope claims from the table below.

Complete Elixir example using JOSE:

```elixir
defmodule MyApp.YouTokens do
  @moduledoc "Verifies You-issued JWTs locally against You's JWKS."

  @jwks_url "https://you.example.com/.well-known/jwks.json"
  @cache_ttl :timer.hours(1)

  def verify(token) do
    with {:ok, keys} <- jwks(),
         {:ok, claims} <- verify_with(keys, token),
         {:ok, claims} <- check_expiry(claims) do
      {:ok, claims}
    end
  end

  # The JWKS can hold several keys during rotation, so pick by the token's
  # `kid` header (fall back to trying all keys) and pin the algorithm.
  defp verify_with(keys, token) do
    kid = kid_of(token)

    keys
    |> Enum.filter(fn {k, _jwk} -> is_nil(kid) or k == kid end)
    |> Enum.find_value({:error, :invalid_signature}, fn {_k, jwk} ->
      case JOSE.JWT.verify_strict(jwk, ["EdDSA"], token) do
        {true, jwt, _jws} -> {:ok, JOSE.JWT.to_map(jwt)}
        _ -> nil
      end
    end)
  end

  defp kid_of(token) do
    [header | _] = String.split(token, ".")

    header
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> Map.get("kid")
  end

  # Fetch and cache the JWKS. Refresh it periodically (key rotation) or
  # on :invalid_signature if you want to tolerate rotation immediately.
  defp jwks do
    case :persistent_term.get({__MODULE__, :jwks}, nil) do
      {fetched_at, keys} when fetched_at > System.monotonic_time(:millisecond) - @cache_ttl ->
        {:ok, keys}

      _ ->
        with %{status: 200, body: %{"keys" => keys}} <- Req.get!(@jwks_url) do
          keys = Map.new(keys, fn k -> {k["kid"], JOSE.JWK.from_map(k)} end)
          :persistent_term.put({__MODULE__, :jwks}, {System.monotonic_time(:millisecond), keys})
          {:ok, keys}
        end
    end
  end

  defp check_expiry({_protected, %{"exp" => exp} = claims}) do
    if DateTime.to_unix(DateTime.utc_now()) > exp do
      {:error, :expired}
    else
      {:ok, claims}
    end
  end
end
```

Any JWT library with Ed25519/EdDSA support works the same way in other
languages: point it at the JWKS URL and validate `exp`.

> Note: tokens currently do not carry an `iss` claim; the issuer is documented
> in the discovery document. Verify signature and `exp`; if You adds `iss`
> later, check it against the discovery document's `issuer`.

### 1.5 Revocation and introspection

Local verification proves a token is authentic and unexpired, but it does not
know whether the token was revoked (You keeps a JTI blocklist). When you need
that check:

- `POST /oauth/introspect`: RFC 7662 token introspection. Client-authenticated
  (`client_id` + `client_secret`); returns whether the token is active and its
  claims. Use sparingly, since it costs a round trip to You per call.
- `POST /oauth/revoke`: RFC 7009 token revocation. Call this when a user
  signs out of your app and you want the token dead immediately.
- `GET /oauth/userinfo`: returns the user's profile claims for a valid
  access token.

For most requests, local verification plus short token lifetimes
(`expires_in`) is enough; introspect only for high-value operations.

---

## 2. Erlang distribution (expert option, trusted BEAM nodes only)

> **Read this before choosing this path.** Erlang distribution is **full
> trust by design**: every connected node can execute arbitrary code on every
> other connected node. There is no authorization layer, no sandbox, no
> per-app credential. The shared cookie is the only gate, and holding it
> means owning You's host and database. This is inherent to OTP, not a
> limitation You can patch. If you are not comfortable reasoning about that
> threat model, use the OIDC path above; it is the default for a reason.

Elixir/Erlang apps running in the same cluster can call You directly over
Erlang distribution via `You.SDK` (no HTTP, no JSON):

```elixir
config :you_sdk, node: :"you@you.example.com"

You.SDK.exchange_code(code, code_verifier: verifier)
# => {:ok, %{user_id: 1, email: "alice@example.com", jwt: "eyJ..."}}

You.SDK.verify_token(jwt)
# => {:ok, %{user_id: 1, email: "...", role: "user"}}

You.SDK.get_user(42)
# => {:ok, %{id: 42, email: "..."}}

You.SDK.revoke_token(jwt)
```

Calls return `{:error, :unreachable}` when You is down or the node can't be
reached, and `{:error, :server_error}` when the call fails inside You.

The rules are non-negotiable:

- **Only connect nodes you fully control.** Never connect a third party's
  node; you would be handing them root on your IAM.
- **Only connect to a You instance you operate.** The trust is mutual: the
  IAM's operator can execute code on your node and sees the credentials
  that flow through it. Integrating with someone else's You? Use OIDC.
- **Never expose EPMD (port 4369) or the distribution ports** to anything
  but your consumer nodes. Never to the public internet.
- **Traffic is not encrypted by default.** Credentials and tokens cross the
  wire in the clear. Only use this over a network you already trust
  (private LAN, WireGuard/Tailscale), or configure TLS distribution.
- **Keep the cookie secret**; treat it like a root credential shared by
  every consumer.

Operational details (ports, cookie rotation, firewalling) are in
[ops/erlang-distribution.md](ops/erlang-distribution.md).

---

## 3. Grant scopes

Scopes are requested at authorize time and decide which claims end up in the
JWT (see `You.IAM.Claims`). Defaults to `email`.

| Scope | Claims added to the JWT |
|-------|-------------------------|
| `email` | `email`: the user's email address |
| `profile` | `email`, `name`: display name (currently the email address) |
| `roles` | `email`, `role`: the user's role in the app the token was issued for (per-app assignment, `"user"` when unassigned). First-party tokens without an app fall back to the account's admin flag |

Every token also carries `sub` (user id), `app` (`"you"`), `jti`, `iat`, and
`exp` regardless of scope.

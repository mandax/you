# You: Identity and Access Management

Cross-app identity, authentication, authorization, and user settings platform. Every service delegates user management to You.

## Architecture

```
You ──── auth, users, roles, 2FA, billing (future)
   │
   ├── myapp ─── verifies You JWTs locally against the JWKS
   └── (future app) ─── same pattern
```

Apps never touch You's database. Communication goes through:
- **OIDC over HTTP**: standard authorization-code + PKCE flow, JWKS, userinfo, introspection, revocation (`/.well-known/*`, `/oauth/*`). Works with any OIDC client library, any language
- **Login UI**: You serves its own LiveView for login, 2FA, magic link
- **Erlang distribution** (expert option, trusted nodes only): the same flows with no HTTP hop, via `You.IAM.Server`
- **`You.SDK`**: a small library that wraps the distribution calls for in-cluster BEAM apps
- **GraphQL** (future): user profile, settings, teams

## Stack

| Layer | Choice |
|-------|--------|
| Runtime | Elixir 1.19.5 / Erlang 29.0.1 |
| Web | Phoenix 1.8.7 / Bandit |
| Database | SQLite via ecto_sqlite3 / exqlite |
| Auth foundation | `mix phx.gen.auth` |
| JWT | Ed25519 via jose |
| 2FA | TOTP via nimble_totp |
| Password hashing | bcrypt_elixir |

## Setup

```bash
mix setup
mix ecto.migrate
mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000).

Running it rather than developing on it? [docs/quickstart.md](docs/quickstart.md)
is `docker compose up` to a working login for a single app, with the multi-app
surface hidden.

## Tests

```bash
mix test
```

## Auth flow

The user authenticates through You's own login UI. Apps redirect to You and
receive a single-use authorization code via callback URL:

```
1. User visits an app → redirected to You/users/log-in?callback_url=...
2. You serves LiveView: email/password + 2FA + magic link
3. On success, You creates a single-use auth code (5 min, hashed)
4. You redirects: 302 callback_url?code=abc123
5. App exchanges the code at POST /oauth/token, authenticating with PKCE
   (public clients) or client_id + client_secret (confidential clients), or
   via You.SDK.exchange_code(code) over Erlang distribution
6. You validates the client and the code, consumes it, and returns access +
   ID + refresh tokens
7. App verifies the JWT locally against You's JWKS
```

Authorization codes reuse the existing `users_tokens` table with
`context: "oauth_code"`, the same hashed-token pattern as magic links.

## SDK

`You.SDK` integrates in-cluster BEAM apps over Erlang distribution. This is the
expert option for nodes you fully control (distribution is full trust; see
[docs/integration.md](docs/integration.md)). Everything it does is also
available over HTTP OIDC.

```elixir
# Exchange auth code for JWT
You.SDK.exchange_code(code, node: :"you@host")
# => {:ok, %{user_id: 1, email: "...", jwt: "..."}}

# Verify a JWT
You.SDK.verify_token(jwt, node: :"you@host")
# => {:ok, %{user_id: 1, email: "...", role: "user"}}

# Look up a user
You.SDK.get_user(42, node: :"you@host")
# => {:ok, %{id: 42, email: "..."}}

# Revoke a session
You.SDK.revoke_token(jwt, node: :"you@host")
```

Configure the You node in the consumer app:

```elixir
config :you_sdk, node: :"you@you.example.com"
```

Returns `{:error, :unreachable}` when You is down and `{:error, :server_error}`
when the call fails inside You.

## API

### OIDC (HTTP, primary)

Standard provider surface, usable by any OIDC client library:

- `GET /.well-known/openid-configuration`: discovery
- `GET /.well-known/jwks.json`: Ed25519 public keys (verify tokens locally)
- `POST /oauth/token`: authorization_code (PKCE or client_secret) and
  refresh_token grants
- `GET /oauth/userinfo`: scoped claims for a Bearer token
- `POST /oauth/introspect`: RFC 7662 (client-authenticated)
- `POST /oauth/revoke`: RFC 7009 (client-authenticated)

### Authentication (user-facing, via LiveView UI)

Login, registration, 2FA, magic link, and settings are served at `/users/*`
on You's own web interface. First-party apps can also authenticate users
headlessly at `/api/auth/*` (client_id + client_secret).

## Documentation

- [Quickstart](docs/quickstart.md): single-app install with `docker compose`
- [Integrating an app](docs/integration.md): OIDC and `You.SDK` integration guide
- [Management REST API](docs/api.md): `/api/v1` for automating users and apps
- [Webhooks](docs/webhooks.md): signed outbound events (Stripe recipe included)
- [Deployment](docs/ops/deploy.md): production deployment guide

## Domain Language

See [CONTEXT.md](CONTEXT.md) for the full glossary of terms.

## Development

```bash
mix phx.server
mix format --check-formatted
mix compile --warnings-as-errors
```

## Contributors

[![Contributors](https://contrib.rocks/image?repo=mandax/you)](https://github.com/mandax/you/graphs/contributors)

## License

[MIT](LICENSE)

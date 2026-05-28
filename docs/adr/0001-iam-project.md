# You — Cross-app Identity and Access Management

Extract user identity, authentication, authorization, and user settings into a standalone IAM project called **You**. Every app (Sockeet, future services) delegates user management to You — no app owns its own user table beyond a lightweight token cache.

## Context

Sockeet currently has a single `admin_users` table with bcrypt-hashed passwords and a session cookie. This works for v0 where there is one admin operating the platform. But the architecture calls for a three-layer separation:

```
You (separate project)
├── Users, auth (password, 2FA, magic link), roles, billing
├── Issues JWTs consumable by all apps
│
├── APPS (Sockeet, future services)
│   ├── Each owns its own domain data
│   ├── Has its own GraphQL API
│   └── Validates You-issued JWTs to authenticate requests
│
└── User-Facing Apps (sockeet-client, deployed separately)
    ├── Consumes app GraphQL APIs
    └── Talks to You for login/logout flows
```

## Decisions

### 1. You is a standalone Elixir/Phoenix application

You is a separate OTP application in its own repository (`~/dev/you` alongside `~/dev/sockeet`). It has its own Ecto repo, its own database, and its own deployment. Apps never touch You's database directly — they call You's API or, for token validation, communicate via Erlang distribution.

### 2. You is built on `mix phx.gen.auth` as the starting point

### 3. JWT over sessions

### 4. Two-factor authentication via TOTP

### 5. Magic link login

### 6. You exposes REST for auth, GraphQL for user data

### 7. You SDK for app integration (not Erlang distribution)

Apps integrate with You via the `You.SDK` module, not Erlang distribution.

- **Token validation**: Apps call `You.SDK.verify(jwt, public_key)` locally using You's Ed25519 public key. No network call per request.
- **Login**: Apps call `You.SDK.login(you_url, email, password)` which makes an HTTP POST to You's `/api/login`.
- **Token revocation**: Apps call `You.SDK.revoke(you_url, jwt)` which makes an HTTP DELETE to You's `/api/logout`.
- **Public key**: You exposes its Ed25519 public key at `GET /.well-known/jwks.json`. Apps fetch it once on startup and cache it.

This means:
- No Erlang node coupling. Apps connect over plain HTTPS.
- Apps asynchronously fetch and cache You's public key for local verification.
- The SDK is a standalone library that can be published as a Hex package.
- Apps never call You's GenServer internals or access its database.

Rejected: Erlang distribution for token validation. Creates tight node coupling, requires both apps to be on the same BEAM cluster, and means You's GenServer is a single point of failure for all auth decisions. HTTP-based token introspection with local JWT verification is simpler, more scalable, and works with non-Elixir clients.

### 8. Secure transport (HTTPS)

### 9. Each app stores a lightweight `iam_tokens` cache

### 10. Per-app roles, not global roles

### 11. No shared database between apps and IAM

### 12. Billing is deferred

### 13. Delivery order

The implementation follows this sequence:

1. ✅ `mix phx.gen.auth` — generate User schema, Accounts context, email infrastructure
2. ✅ **JWT layer** — replace sessions with JWT on login/logout; add `jose` signing/verification
3. ✅ **Magic link** — reuse `UserToken` pattern for email-based passwordless login
4. ✅ **2FA** — add `nimble_totp` column to User, pre-auth token flow, recovery codes
5. **SDK module** — build `You.SDK` with local JWT verification and HTTP client ← CURRENT
6. **JWKS endpoint** — expose Ed25519 public key at `GET /.well-known/jwks.json`

Steps 1–5 are self-contained within You. Step 6 adds the public key discovery endpoint.

## Status

Proposed — replaces previous version of this ADR.

## Consequences

- You owns the full authentication flow. Apps never see passwords, TOTP secrets, or 2FA codes.
- Apps validate JWTs locally using You's cached public key — no HTTP calls per request.
- The `You.SDK` is a standalone library consumable as a Hex or path dependency.
- Losing the HTTP connection to You means apps can't log in, but existing JWTs remain valid until expiry.

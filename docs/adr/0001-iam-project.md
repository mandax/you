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

### 7. Erlang distribution for app↔You communication with SDK

You exposes `You.IAM.Server` — a GenServer registered on the You node.
Consumer apps communicate with it via Erlang distribution, wrapped by the
`You.SDK` dependency:

- **Token validation**: `You.SDK.verify_token(jwt)` →
  `GenServer.call({You.IAM.Server, you_node}, {:verify_token, jwt})` →
  You validates signature, expiry, blocklist → returns user info
- **User lookup**: `You.SDK.get_user(user_id)` →
  `GenServer.call({You.IAM.Server, you_node}, {:get_user, user_id})` →
  returns `%{id, email}`
- **Token revocation**: `You.SDK.revoke_token(jwt)` →
  `GenServer.call({You.IAM.Server, you_node}, {:revoke_token, jwt})` →
  You adds JTI to blocklist

The SDK (`You.SDK`) is a dependency library that apps include in their
`mix.exs`. It handles node resolution, timeouts, and returns
`{:error, :unreachable}` when You is down. Apps never call You's
GenServer internals or access its database directly.

Benefits:
- Sub-millisecond latency on the same node, millisecond across a cluster
- The SDK is a standalone Hex package
- No HTTP overhead per request
- If You is unreachable, the app degrades gracefully

### 8. Secure Erlang distribution with TLS

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
5. **SDK module** — build `You.SDK` wrapping Erlang distribution calls ← CURRENT
6. **Sockeet integration** — update Sockeet to use `You.SDK` as a dependency

Steps 1–5 are self-contained within You. Step 6 is in the Sockeet repo.

## Status

Proposed — replaces previous version of this ADR.

## Consequences

- You owns the full authentication flow. Apps never see passwords, TOTP secrets, or 2FA codes.
- Apps connect to You via Erlang distribution for token validation — sub-millisecond latency on the same node.
- The `You.SDK` is a standalone Hex package that wraps the GenServer calls.
- Losing the Erlang connection to You means SDK returns `{:error, :unreachable}`.

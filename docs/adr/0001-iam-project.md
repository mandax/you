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

### 7. Erlang distribution for app↔You communication

Sockeet and You run as connected Elixir nodes on the same cluster. Communication happens via Erlang process messages, not HTTP:

- **Token validation**: Sockeet sends `{:verify_token, jwt}` to a named GenServer on You → You validates signature, expiry, blocklist → returns user info
- **User lookup**: Sockeet sends `{:get_user, user_id}` → You returns `{username, email, role}` (used to enrich API key displays and populate the local token cache)
- **Token revocation**: Sockeet sends `{:revoke_token, jti}` → You adds JTI to blocklist

This means:
- No HTTP overhead for auth validation
- The Erlang node connection can be secured (see decision 8)
- Both apps share the same Erlang cookie for node authentication
- Message protocol is defined by You's public API module — apps never call You's GenServer internals directly

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
5. **Erlang distribution** — connect Sockeet + You nodes, define message protocol for token validation ← CURRENT
6. **Sockeet migration** — swap `AdminAuth` plug for JWT validation via Erlang message, drop `admin_users`, add `iam_tokens` table

Steps 1–4 are self-contained within You. Step 5 requires changes in both repos. Step 6 is purely on the Sockeet side.

## Status

Proposed — replaces previous version of this ADR.

## Consequences

- You owns the full authentication flow. Apps never see passwords, TOTP secrets, or 2FA codes.
- Apps connect to You via Erlang distribution for token validation — no HTTP calls per request.
- Losing the Erlang connection to You means apps degrade gracefully using their local `iam_tokens` cache for a configurable grace period.

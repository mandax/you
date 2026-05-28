# You — Identity and Access Management

Cross-app identity, authentication, authorization, and user settings platform. Every service in the homelab delegates user management to You.

## Language

**User**:
A person with an account. Has a username, email, password hash, display name, and optional avatar. A user belongs to zero or more teams.
_Avoid_: Admin, account, member

**Session**:
An authenticated login session issued after successful authentication. Represented as a JWT with a unique JTI. Sessions are revocable — the blocklist is checked on each request.
_Avoid_: Token, cookie (JWTs are the token format; sessions are the concept)

**Role**:
A named set of permissions scoped to a specific app. Example: `(sockeet, user-42) → admin`. Roles are always `(app_slug, user_id) → role_name` — never global.
_Avoid_: Permission, scope, privilege

**App**:
A service that integrates with You for authentication (Sockeet, future services). Each app has an API key for server-to-server communication and a configured set of allowed roles.
_Avoid_: Service, client, integration

**Team** (future):
A group of users that share billing, settings, and app access. A user can belong to multiple teams. Teams have a billing plan.
_Avoid_: Organization, workspace, group

**Billing Plan** (future):
A subscription tier that determines per-team quotas: max users, max apps, API rate limits, storage. Reserved in the schema but not active until payment integration is built.
_Avoid_: Tier, subscription, pricing plan

**API Key** (machine-to-machine):
A Bearer token used by apps to call You's internal endpoints (token validation, user lookup). Not to be confused with per-app API keys (e.g., Sockeet's `sk_` keys for content extraction).
_Avoid_: Token, secret, credential

**Two-Factor Authentication (2FA)**:
An optional second factor on login using TOTP (time-based one-time passwords). When enabled, password validation returns a pre-auth token, which is exchanged for a final JWT only after a valid TOTP code is submitted. Recovery codes (8 single-use hashed codes) are generated at setup.
_Avoid_: MFA, two-step verification

**Magic Link**:
A passwordless login flow. The user enters their email, You sends a short-lived signed link (15 min), and clicking it exchanges the link token for a JWT. Single-use — consumed on first click.
_Avoid_: Passwordless login, email auth, one-time link

**Pre-auth Token**:
A short-lived JWT (5 minutes, single-use) issued after successful password check when 2FA is enabled. Exchanged for a final session JWT after TOTP verification. Contains no role or app info — only a marker that the password half of auth is complete.
_Avoid_: Partial token, stage-1 token

**JWT**:
The token format for authenticated sessions. Signed with You's Ed25519 key. Contains `sub` (user UUID), `email`, `app` (app slug), `role`, `jti` (unique ID for revocation), `iat`, `exp`. Apps validate locally using You's public key.
_Avoid_: Token, session token, bearer token

**SDK** (`You.SDK`):
The official library for integrating apps with You. Apps add it as a Hex or path dependency. Provides functions that call You's `You.IAM.Server` via Erlang distribution (`GenServer.call`). Handles node lookup, timeout, and graceful degradation when You is unreachable.
_Avoid_: HTTP client, REST wrapper, direct GenServer calls

**Erlang Distribution**:
The communication channel between You and apps (Sockeet, future services). Connected nodes exchange process messages. You registers `You.IAM.Server` — a GenServer that handles `{:verify_token, jwt}`, `{:get_user, user_id}`, `{:revoke_token, jwt}`. Apps use `You.SDK` which wraps these calls.
_Avoid_: RPC, REST, node coupling

**IAM Token Cache** (`iam_tokens` table in each app, optional):
Lightweight local cache stored in each app's database. Stores `you_user_id`, username, email, role, and last validated timestamp. Used for display and graceful degradation when You is unreachable.
_Avoid_: User table, user cache, auth table

## Context Map

You is the center of a hub-and-spoke architecture:

```
You ──── auth, users, roles, billing
   │
   ├── Sockeet ─── validates You tokens, owns its domain data
   ├── (future app) ─── same pattern
   └── User-facing apps ─── consume You's GraphQL for auth UI
```

Apps never touch You's database. All communication goes through You's API.

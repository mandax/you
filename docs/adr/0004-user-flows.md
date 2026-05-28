# User flows and session expiry

Design the user-facing authentication flows (signin, signout, forgot password, 2FA), how the target app is identified without URL tampering, and how session expiry is configured.

## Signin flow

```
Browser                     You                          App (Sockeet)
   │                         │                              │
   │   visit /dashboard      │                              │
   │─────────────────────────│─────────────────────────────►│
   │                         │                              │
   │                         │     not authenticated        │
   │                         │    redirect to You/login     │
   │                         │    ?callback_url=...         │
   │◄────────────────────────│──────────────────────────────│
   │                         │                              │
   │  GET /login             │                              │
   │  ?callback_url=...     │                              │
   │────────────────────────►│                              │
   │                         │                              │
   │  ┌─ You looks up app by matching callback_url         │
   │  │  against registered callback URL prefixes.         │
   │  │  If no match → app defaults to "you".             │
   │  │  No app parameter in the URL — tamper-proof.       │
   │  └─────────────────────────────────────────────────── │
   │                         │                              │
   │  ┌─ If valid You session cookie exists →              │
   │  │  skip login form, go straight to authorize.        │
   │  └─────────────────────────────────────────────────── │
   │                         │                              │
   │  ┌─ If no session → show login form                   │
   │  │  - email/password                                  │
   │  │  - or magic link (email-based)                     │
   │  └─────────────────────────────────────────────────── │
   │                         │                              │
   │  ┌─ After auth check, if 2FA enabled →               │
   │  │  show TOTP form (or recovery code fallback).       │
   │  └─────────────────────────────────────────────────── │
   │                         │                              │
   │  ┌─ All checks pass → generate auth code              │
   │  │  - single-use                                      │
   │  │  - 5 minute expiry (configurable)                  │
   │  │  - tagged with app_id from lookup                  │
   │  │  - stored in users_tokens (context: oauth_code)   │
   │  └─────────────────────────────────────────────────── │
   │                         │                              │
   │  302 callback_url                                      │
   │  ?code=abc123                                         │
   │◄────────────────────────│                              │
   │                         │                              │
   │  GET /callback                                         │
   │  ?code=abc123                                         │
   │─────────────────────────│─────────────────────────────►│
   │                         │                              │
   │                         │   You.SDK.exchange_code(code)│
   │                         │────────────────────────────►│
   │                         │  (Erlang distribution)      │
   │                         │◄────────────────────────────│
   │                         │   {:ok, %{jwt, user_id,     │
   │                         │            email, app}}      │
   │                         │                              │
   │  200 + Set-Cookie       │                              │
   │  (or 200 + Bearer JWT)  │                              │
   │◄────────────────────────│──────────────────────────────│
```

Key properties:
- No `app` parameter in the URL — tamper-proof by design
- You session cookie is separate from app JWTs — signing out of one app doesn't affect another
- The JWT's `app` claim is set by database lookup of the callback URL, not by client input

## Signout flow

Two separate actions:

**App-level signout** (user leaves one app):
1. App calls `You.SDK.revoke_token(jwt)` → You adds the JTI to the blocklist
2. The app discards its JWT (clears cookie/localStorage — its choice)
3. The You session cookie remains valid — user is still signed into You

**You-level signout** (user leaves You entirely):
1. App redirects to `You/logout`
2. You clears the session cookie
3. All auth codes are invalidated by session clear
4. App JWTs already issued remain valid until expiry — they are not invalidated by You logout

## Forgot password flow

Reuses phx.gen.auth's existing pattern:

1. User clicks "Forgot password" on You's login page
2. User enters email
3. You sends a password reset link (15-minute expiry, hashed token in `users_tokens`)
4. User clicks link → sets new password
5. All existing session tokens for that user are deleted (`update_user_and_delete_all_tokens`)
6. User is redirected to login

Security: password reset invalidates all active You sessions. App JWTs remain valid until they expire — the app can choose to check revocation status.

## 2FA verification flow

1. On login, after password/magic-link authentication succeeds, check `user.totp_enabled`
2. If enabled, return a pre-auth page (not yet a session)
3. User enters TOTP code from authenticator app
4. You validates against stored `totp_secret` via `NimbleTOTP.valid?/2`
5. If valid → proceed to auth code generation
6. If invalid → show error, allow retry
7. If user has no access to authenticator → allow recovery code fallback (single-use, bcrypt-hashed)

The pre-auth state is ephemeral (in-memory, not persisted). If the user navigates away, they start over.

## Session expiry (configurable)

All expiry durations are stored in a database `settings` table (key-value), readable at login and auth code generation time. Defaults:

| Setting | Key | Default | Rationale |
|---------|-----|---------|-----------|
| You session cookie | `session_expiry_hours` | 24 hours | A management portal session. Absolute — not sliding. |
| App JWT | `jwt_expiry_hours` | 1 hour | Short window for a credential sent on every request. |
| Auth code | `code_expiry_minutes` | 5 minutes | Short enough to prevent replay, long enough for a redirect. |
| Magic link | `magic_link_expiry_minutes` | 15 minutes | Standard phx.gen.auth default. Long enough for email delivery. |

All defaults are tight. The settings table allows operators to relax them if needed (homelab, trusted network).

Expiry is **absolute**: the credential expires exactly N hours after issuance, regardless of activity. No sliding renewal.

## Considered Options

**`app` in the URL** — rejected. App A can forge `app=app_b` and get a JWT scoped to App B. The app must be identified by matching the callback URL against a registered prefix database.

**Sliding session expiry** — rejected. A stolen cookie stays valid indefinitely as long as it's used. Absolute expiry forces re-authentication at a fixed interval.

**Single global session** — rejected. A user can be signed into You (cookie on you.example.com) without being authorized for every app. App JWTs are per-app. The You session is only used to skip the login form on subsequent app authorizations.

## Consequences

- The `settings` table needs a migration and a GenServer or cache for reading at issuance time.
- The auth code exchange must look up the app by callback URL prefix, not by a URL parameter.
- The JWT's `app` claim defaults to `"you"` when no registered app matches.
- App-level signout and You-level signout are separate concepts documented explicitly.
- Forgot password invalidates You sessions but not existing app JWTs (they expire naturally).

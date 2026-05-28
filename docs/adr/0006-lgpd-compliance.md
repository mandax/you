# LGPD compliance — data access, consent, deletion, and retention

Design the data privacy features required by Lei Geral de Proteção de Dados Pessoais (LGPD). Affects how user data is stored, shared with apps, accessed by the user, and deleted upon request.

## Personal data inventory

What You stores:

| Table | Fields | Classification |
|-------|--------|---------------|
| `users` | email, hashed_password, confirmed_at, totp_secret, totp_enabled, timestamps | Personal (email), sensitive (password hash, TOTP secret) |
| `users_tokens` | token, context, sent_to (email copy), authenticated_at, user_id, inserted_at | Personal (email in sent_to, activity timestamps) |
| `recovery_codes` | code_hash, used, user_id, inserted_at | Personal (linked to user) |

Legal basis: **contract execution** (Art. 7, II) for authentication data. **Consent** (Art. 7, I) for data shared with third-party apps via grant scopes.

## Decisions

### 1. Grant scopes

When an app requests authorization, it declares which scopes it needs. Scopes filter what claims go into the JWT.

| Scope | Claims in JWT |
|-------|---------------|
| `email` | `sub`, `email` |
| `profile` | `sub`, `email`, `name`, `avatar_url` |
| `roles` | `sub`, `email`, `role` |

The app passes `scope` in the redirect URL: `/login?callback_url=...&scope=email+profile`. Unlike `app` (rejected as tamperable), `scope` is safe because the app can only reduce what it receives — it cannot escalate. The default scope (if none specified) is `email`.

The user sees a consent screen in You's LiveView before the auth code is issued: "Sockeet wants access to your email address and profile information."

### 2. Consent records

Each authorization creates a `consents` record:

```elixir
schema "consents" do
  belongs_to :user, User
  belongs_to :app, App
  field :scopes, {:array, :string}
  field :granted_at, :utc_datetime
  field :expires_at, :utc_datetime
  timestamps()
end

unique_index [:user_id, :app_id]
```

The IAM Server checks the consent record at auth code exchange time. If the consent is missing or expired (`expires_at < now`), the exchange fails — the user must re-authorize through the full redirect flow. Consent expires when the app JWT expires (the `jwt_expiry_hours` setting).

### 3. Access data endpoint

`GET /users/settings/access_data` — authenticated via You session. Returns JSON with the user's personal data:

```json
{
  "email": "user@example.com",
  "confirmed_at": "2026-05-28T18:00:00Z",
  "totp_enabled": false,
  "created_at": "2026-05-28T18:00:00Z",
  "updated_at": "2026-05-28T18:00:00Z",
  "apps": [
    {"name": "Sockeet", "scopes": ["email", "profile"], "granted_at": "..."}
  ]
}
```

No download, no file — the URL itself is the access point. Named after LGPD's "right to access" (Art. 9).

### 4. Account anonymization (right to deletion)

When a user requests account deletion, their data is anonymized — not deleted outright. Referential integrity with app caches (`iam_tokens`) is preserved.

```
email        → "redacted-{uuid}@anonymized.you"
hashed_password → nil
totp_secret  → nil
totp_enabled → false
confirmed_at → nil
```

All `users_tokens` entries for the user are deleted. All `recovery_codes` for the user are deleted. All `consents` for the user are deleted. The user row stays but is functionally dead — no login possible. Apps that validate a cached JWT after anonymization will get `{:error, :not_found}` or a deleted-user indicator.

### 5. Data retention cleanup

A periodic task prunes expired data:

| Data | Retention | Cleanup |
|------|-----------|---------|
| Session tokens | 14 days | Ecto query (already enforced by phx.gen.auth) |
| Auth codes | 5 minutes | Ecto query |
| `jti_revoked` entries | max(`app_jwt_expiry_hours`) + 1 hour grace | Periodic job deletes entries where `inserted_at < now - (jwt_expiry + 1h)` |
| Email change tokens | 7 days | Ecto query (already enforced) |
| Magic link tokens | 15 minutes | Ecto query (already enforced) |

The `jti_revoked` cleanup is the only new work — these entries accumulate because they have no natural expiry. A `:timer.send_interval` in the supervision tree runs the cleanup hourly.

### 6. DPO contact

Configurable via settings: `dpo_email` (default: `nil`). Shown in the login page footer and in "Contact" sections of the UI. Not a code feature — just a setting display.

## Consequences

- Migration: `consents` table, `users.is_admin`, `settings`, `apps` (from ADR 0005).
- The `scope` parameter in the redirect URL is new but safe (app can only self-limit).
- Consent records are checked at auth code exchange time — new IAM Server logic.
- Anonymization is a new Accounts function: `Accounts.anonymize_user(user)`.
- The access data endpoint is new controller action: `UserSettingsController.access_data`.
- The `jti_revoked` cleanup runs via a periodic task in the supervision tree.
- All existing test flows must be updated to account for the scopes filtering and consent checks.

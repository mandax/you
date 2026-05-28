# Admin system and instance configuration

Design the admin system for You: how operators configure the IAM instance, register apps, manage user roles, and bootstrap the first admin.

## Decisions

### 1. Admin is a User flag

No separate admin table, login flow, or schema. A `users.is_admin` boolean (`default: false`) gates access to the admin panel and the settings mutation endpoints in `You.IAM.Server`.

Promoting a user to admin requires an existing admin to do it through the admin UI. If no admin exists yet, the bootstrap mix task handles it (see decision 2).

### 2. First admin via mix task

`mix you.bootstrap_admin` — interactive, colored. Prompts for email and password, creates the user if they don't exist, sets `is_admin = true`. Idempotent: if an admin already exists with that email, it prints a message and exits.

### 3. Settings table

A single `settings` table with key-value pairs. Read at auth issuance time. Cached in a GenServer or ETS for hot-path reads.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `session_expiry_hours` | integer | 24 | How long the You session cookie lasts |
| `jwt_expiry_hours` | integer | 1 | How long app JWTs last |
| `code_expiry_minutes` | integer | 5 | Auth code expiry |
| `magic_link_expiry_minutes` | integer | 15 | Magic link token expiry |

All values are absolute, non-sliding. The admin panel renders a form to edit these.

### 4. Apps table

```elixir
schema "apps" do
  field :slug, :string         # "sockeet"
  field :name, :string         # "Sockeet"
  field :callback_url, :string # "https://sockeet.example.com/auth/callback"
  timestamps()
end
```

One callback URL per app for v1. Multiple environments use separate app registrations. The callback URL is matched as a prefix during the auth code flow — `?code=...` is appended by You.

### 5. Admin panel via LiveView

The admin panel lives at `/admin` and uses Phoenix LiveView. Gated by a `require_admin` plug that checks `conn.assigns.current_user.is_admin`. Non-admins get a 404.

Sections:
- **Dashboard** — overview stats (users, apps, active sessions)
- **Settings** — edit expiry durations
- **Apps** — register, edit, delete app registrations
- **Users** — list users, promote/demote to admin

### 6. Admin operations over Erlang distribution

Settings reads happen on every auth code exchange (to set JWT expiry) and session creation (to set session expiry). These are hot-path reads. The settings are cached in a GenServer/ETS and refreshed when updated through the admin panel.

Settings mutations and user role changes also go through `You.IAM.Server` so the SDK can call them in the future, but for v1 they only happen through the admin LiveView.

## Consequences

- Migration: add `is_admin` to `users`, create `settings` and `apps` tables.
- A `You.Settings` GenServer caches settings values for hot-path reads.
- The auth code exchange reads `jwt_expiry_hours` from settings (fallback to 1).
- Session creation reads `session_expiry_hours` from settings (fallback to 24).
- The admin LiveView is a new surface — no changes to the existing user-facing flows.

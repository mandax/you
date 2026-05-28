# Sockeet Migration Guide: Swapping to You IAM

## Overview

Migrate Sockeet from its local `admin_users` table and session cookie auth to
JWT-based authentication delegated to the **You** IAM service.

## Prerequisites

- You is deployed and reachable
- Erlang distribution is configured between Sockeet and You nodes
- You's Ed25519 public key is available

## Migration Steps

### 1. Add `iam_tokens` table

Run a migration in Sockeet to create the lightweight token cache:

```elixir
# priv/repo/migrations/xxxxxx_create_iam_tokens.exs
defmodule Sockeet.Repo.Migrations.CreateIamTokens do
  use Ecto.Migration

  def change do
    create table(:iam_tokens) do
      add :you_user_id, :string, null: false
      add :username, :string
      add :email, :string
      add :role, :string
      add :jti, :string
      add :last_validated_at, :utc_datetime
      timestamps()
    end

    create unique_index(:iam_tokens, [:you_user_id])
  end
end
```

### 2. Add You IAM client dependency

Add to Sockeet's `mix.exs`:

```elixir
# Or, for local development, clone this into ~/dev/you
# and reference it as a path dependency:
{:you, path: "../you", only: [:dev, :test]}
```

For production, the IAM protocol is just GenServer calls — no Hex dependency
needed if you copy `You.IAM.Client` into Sockeet's codebase.

### 3. Configure Erlang distribution

In Sockeet's `config/runtime.exs`:

```elixir
config :you_iam_client,
  node: :"you@you.internal.example.com",
  timeout: 5_000
```

Set the Erlang cookie to match You's cookie in `vm.args`:

```
-setcookie you_cookie
```

### 4. Create the JWT auth plug

Replace or extend `SockeetWeb.AdminAuth` with a plug that uses JWT validation:

```elixir
defmodule SockeetWeb.JWTAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> jwt] <- get_req_header(conn, "authorization"),
         {:ok, info} <- You.IAM.Client.verify_token(jwt) do
      # Cache in iam_tokens
      cache_token!(info, jwt)
      assign(conn, :current_user, info)
    else
      {:error, :unreachable} ->
        # Degrade to cache
        case get_cached_token(conn) do
          nil -> unauthorized(conn)
          info -> assign(conn, :current_user, info)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
```

### 5. Grace period and cache refresh

The `iam_tokens` cache allows continued operation when You is unreachable:

- **Grace period**: configurable, default 15 minutes after last validation
- **Cache refresh**: fields (username, email) are refreshed from You via
  `You.IAM.Client.get_user/1` when `last_validated_at` is more than 1 hour old
- On refresh failure (You still down), the existing cache entry is kept and
  the grace period clock resets

### 6. Data migration: transfer admin users

Before dropping `admin_users`, each admin must create an account in You:

1. Admin visits You's registration page → `POST /users/register`
2. Admin sets a password → `POST /users/settings` to set password
3. Admin maps their old Sockeet role to a You role via the API
4. API keys owned by the admin are re-associated with the new `you_user_id`

**For v0 with a single admin**, this is a manual one-time step.
For future multi-user setups, build a bulk migration script.

### 7. Drop `admin_users` table

After all users are migrated and the new auth plug is deployed:

```elixir
# priv/repo/migrations/xxxxxx_drop_admin_users.exs
defmodule Sockeet.Repo.Migrations.DropAdminUsers do
  use Ecto.Migration

  def change do
    drop table(:admin_users)
  end
end
```

## Rollback plan

If auth breaks, revert to the old `AdminAuth` plug (keep it in the codebase
during the transition). The `admin_users` table should NOT be dropped until
the new auth flow has been validated in production for at least one week.

## Testing locally

1. Start both apps in dev:

   ```bash
   # Terminal 1 - start You
   cd ~/dev/you && mix phx.server

   # Terminal 2 - start Sockeet with connected node
   cd ~/dev/sockeet && iex --sname sockeet -S mix phx.server
   ```

2. Since both apps run on the same machine, set the Erlang cookie:

   ```bash
   # ~/.iex.exs or in config
   Node.set_cookie(:you_cookie)
   ```

3. In a test node, verify the connection:

   ```elixir
   Node.connect(:you@your-machine-name)
   You.IAM.Client.verify_token(jwt)
   ```

# Erlang Distribution Protocol for You↔App Communication

Define the message protocol and server architecture for Erlang distribution between You and its consuming apps.

## Context

You and its consumer apps run as connected Elixir nodes in the same cluster. Instead of HTTP calls for token validation, user lookup, and revocation, they communicate via Erlang process messages. This avoids HTTP latency, serialization overhead, and an extra failure domain for every authenticated request.

## Decisions

### 1. You runs `You.IAM.Server` — a named GenServer

You registers a GenServer under the name `:iam_server` on the local node. Apps send messages to `{:iam_server, node_where_you_runs}` via `GenServer.call/2`.

- **Registered name**: `You.IAM.Server` locally, accessible to remote nodes as `{You.IAM.Server, you_node}`
- **Timeout**: 5 seconds per call. If You is unreachable, the app degrades to its local `iam_tokens` cache.
- **Supervision**: Part of You's supervision tree under `You.Supervisor`, strategy `:permanent` (restart on crash).

### 2. Message protocol

All messages use the `GenServer.call/2` pattern. Responses use tagged tuples.

| Message | Direction | Response |
|---------|-----------|----------|
| `{:verify_token, jwt}` | App → You | `{:ok, %{user_id: integer, email: string, role: string}}` or `{:error, :expired \| :invalid_signature \| :revoked}` |
| `{:get_user, user_id}` | App → You | `{:ok, %{id: integer, email: string}}` or `{:error, :not_found}` |
| `{:revoke_token, jwt}` | App → You | `:ok` |

The response maps are flat key-value structs — no Ecto schemas cross the node boundary.

### 3. IAM.Client helper on the app side

Each consumer app uses `You.IAM.Client` (or an equivalent module) which wraps `GenServer.call/2` with the correct node name, timeout, and error handling. This module lives in the **YOUR** repo and apps add it as a dependency or copy the protocol.

```elixir
# In a consumer app's code:
You.IAM.Client.verify_token(jwt)
You.IAM.Client.get_user(user_id)
You.IAM.Client.revoke_token(jti)
```

Each function handles three cases:
1. You responds normally → return result
2. You is unreachable (`{:EXIT, _}`) → log warning, return `{:error, :unreachable}`
3. Timeout → log warning, return `{:error, :timeout}`

### 4. Token validation is the hot path — kept fast

`verify_token` does:
1. JOSE signature check (sub-millisecond)
2. Expiry check (in-memory)
3. Blocklist check (Repo.get_by on `users_tokens` — indexed)

No database writes on the hot path. Blocklist lookup is a single indexed query.

### 5. During development, test within a single node

For dev and test, You and the app run on the same node. `GenServer.call(You.IAM.Server, msg)` works locally without Erlang distribution. This simplifies testing — just start You's supervision tree in the test.

## Status

Proposed

## Consequences

- Apps validate tokens via GenServer.call — sub-millisecond latency when You is on the same node, millisecond when on a nearby node in the same cluster.
- Apps degrade gracefully: if You is unreachable, they use the local `iam_tokens` cache with a configurable grace period (default 15 min).
- The IAM module is the public API boundary — apps never call You's Ecto schemas or Repo directly.
- The `iam_tokens` cache in each app means user display names are available even when You is down.

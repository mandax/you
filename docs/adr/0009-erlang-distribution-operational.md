# Erlang distribution — node naming, discovery, and configuration

How You exposes its Erlang node for consumer apps (Sockeet, etc.) to connect
via Erlang distribution, and how those apps discover You's node name.

## Context

ADR 0002 defined the message protocol between You and consumer apps via
`GenServer.call({You.IAM.Server, you_node}, msg)`. However, it left open
how `you_node` is determined and how the two sides agree on distribution
parameters (cookie, ports).

This ADR fills that gap. It does NOT change the message protocol — only how
nodes are named and discovered.

## Decisions

### 1. Node name via container env var, documented in settings

You's Erlang node name is configured via the `RELEASE_NODE` environment
variable at container start. It is NOT configured in the database because
Erlang distribution must be active before the Elixir application boots
(the VM is already distributed by the time `Application.start` runs).

The settings table stores `erlang_node_name` as a *reference copy* — it
documents what value the operator intended to set, but changing it in the
admin panel alone does NOT reconfigure the live Erlang node. The operator
must also restart the container with the matching `RELEASE_NODE` env var.

| Where | Key | Purpose |
|-------|-----|---------|
| Env var | `RELEASE_NODE` | Actual Erlang VM config (required) |
| Settings | `erlang_node_name` | Reference/documentation for consumers |

### 2. EPMD port is the standard discovery mechanism

EPMD (Erlang Port Mapper Daemon, port 4369) is the standard way Erlang nodes
discover each other. Consumer apps connect to You by knowing its hostname
and sharing the same Erlang cookie.

No additional discovery service (libcluster, DNS, etc.) is needed for v1.
You runs as a single node. Consumer apps are configured statically with
You's node name.

For future multi-node You deployments, libcluster or similar can be added
without changing the message protocol.

### 3. Cookie is a shared secret, configured via env var

The Erlang cookie is set via `RELEASE_COOKIE` env var. It must match on all
nodes in the cluster. This is a deployment concern — the cookie is set in
the container orchestration (Docker Compose, Kubernetes Secret, etc.) and
never stored in the database.

### 4. `RELEASE_DISTRIBUTION` must be explicitly enabled

Elixir releases default `RELEASE_DISTRIBUTION` to `none` — Erlang
distribution is disabled out of the box. A `rel/env.sh.eex` sets it to
`name` by default, overridable via the env var. Without this,
`GenServer.call({You.IAM.Server, remote_node}, msg)` hangs and times out
because the remote VM doesn't accept distribution connections.

### 5. Consumer apps configure You's node name statically

Consumer apps (Sockeet) configure You's node name via their own config:

```elixir
# In the consumer app's config/runtime.exs
config :you_sdk, node: String.to_atom(System.get_env("YOU_NODE", "you@you.internal"))
```

No runtime discovery for v1. The operator ensures `YOU_NODE` matches
You's `RELEASE_NODE` at deployment time.

### 6. No libcluster or automatic clustering for v1

libcluster adds complexity (strategy selection, connection management,
split-brain handling) that is not needed when the deployment is a single
You node with a handful of statically-configured consumer apps.

Adding libcluster later is backwards-compatible — the SDK's node option
would become optional (auto-discovered) while still allowing explicit
overrides.

### 7. Settings table as a discovery hint (optional)

The `erlang_node_name` setting in You's database acts as a hint for
operators and for tooling. A consumer app *could* query You's REST-like
settings endpoint (via a future admin API) to discover the node name,
but this is not the primary path — it's a secondary verification channel.

## Status

Proposed — supersedes the Erlang distribution configuration gap in ADR 0002.

## Consequences

- You's node name is set at container start via `RELEASE_NODE` — immutable at runtime.
- The settings `erlang_node_name` is a reference copy, re-deployed via the seed migration.
- Consumer apps configure You's node name statically in their own config.
- EPMD port 4369 must be exposed between You and consumer app containers.
- All nodes must share the same `RELEASE_COOKIE` value.
- Adding automatic discovery (libcluster) is deferred to a future ADR.

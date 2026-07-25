# Erlang distribution: node naming, discovery, and configuration

How You exposes its Erlang node for consumer apps to connect
via Erlang distribution, and how those apps discover You's node name.

## Context

ADR 0002 defined the message protocol between You and consumer apps via
`GenServer.call({You.IAM.Server, you_node}, msg)`. However, it left open
how `you_node` is determined and how the two sides agree on distribution
parameters (cookie, ports).

This ADR fills that gap. It does NOT change the message protocol, only how
nodes are named and discovered.

## Decisions

### 1. Node name via container env var, documented in settings

You's Erlang node name is configured via the `RELEASE_NODE` environment
variable at container start. It is NOT configured in the database because
Erlang distribution must be active before the Elixir application boots
(the VM is already distributed by the time `Application.start` runs).

The settings table stores `erlang_node_name` as a *reference copy*: it
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

### 3. Cookie stored encrypted in settings, applied at boot and dynamically

The Erlang cookie is stored in the `erlang_cookie` setting in the database,
**encrypted at rest** using `Phoenix.Token.encrypt/3`. This uses AES-256-GCM
with a key derived from `secret_key_base`, the same key derivation that
Phoenix uses for signed/encrypted cookies. No additional dependencies.

```elixir
# On save (admin panel or seed)
ciphertext = Phoenix.Token.encrypt(YouWeb.Endpoint, "erlang_cookie", plaintext)
# Stored as base64 ciphertext in settings.value

# At boot / on change
{:ok, plaintext} = Phoenix.Token.decrypt(YouWeb.Endpoint, "erlang_cookie", ciphertext)
Node.set_cookie(node, String.to_atom(plaintext))
```

A `CookieSync` GenServer runs at boot after the Repo starts, reads the
setting, decrypts it, and applies it via `Node.set_cookie/1`. When the
admin changes the cookie in the settings page, it is encrypted, persisted,
and applied immediately.

The `rel/env.sh.eex` sets a random per-boot bootstrap cookie when
`RELEASE_COOKIE` is unset (fail closed, no predictable default); the DB
value (decrypted) overrides it moments later.

**Implications of dynamic application:**

- Changing the cookie breaks all existing Erlang distribution connections
  immediately. Consumer apps must update their cookie and reconnect.
- In-flight `GenServer.call` messages from consumer apps fail with
  `{:error, :unreachable}` until the consumer side is updated.
- The operator should coordinate cookie rotation: update consumer apps first
  (new cookie), then update You's settings, or accept brief downtime.

**Encryption properties:**

- Rotating `secret_key_base` invalidates all encrypted settings, the same
  as Phoenix encrypted session cookies.
- Each encrypted value uses a unique salt (the setting key), so reusing the
  same `secret_key_base`-derived key produces different ciphertexts per field.
- The base64 ciphertext is ~40% larger than the plaintext, negligible for
  a short cookie value.

### 4. `RELEASE_DISTRIBUTION` must be explicitly enabled

Elixir releases default `RELEASE_DISTRIBUTION` to `none`: Erlang
distribution is disabled out of the box. A `rel/env.sh.eex` sets it to
`name` by default, overridable via the env var. Without this,
`GenServer.call({You.IAM.Server, remote_node}, msg)` hangs and times out
because the remote VM doesn't accept distribution connections.

### 5. Consumer apps configure You's node name statically

Consumer apps configure You's node name via their own config:

```elixir
# In the consumer app's config/runtime.exs
config :you_sdk, node: String.to_atom(System.get_env("YOU_NODE", "you@you.example.com"))
```

No runtime discovery for v1. The operator ensures `YOU_NODE` matches
You's `RELEASE_NODE` at deployment time.

### 6. No libcluster or automatic clustering for v1

libcluster adds complexity (strategy selection, connection management,
split-brain handling) that is not needed when the deployment is a single
You node with a handful of statically-configured consumer apps.

Adding libcluster later is backwards-compatible: the SDK's node option
would become optional (auto-discovered) while still allowing explicit
overrides.

### 7. Settings table as a discovery hint (optional)

The `erlang_node_name` setting in You's database acts as a hint for
operators and for tooling. A consumer app *could* query You's REST-like
settings endpoint (via a future admin API) to discover the node name,
but this is not the primary path; it's a secondary verification channel.

## Status

Proposed, superseding the Erlang distribution configuration gap in ADR 0002.

## Consequences

- You's node name is set at container start via `RELEASE_NODE`, immutable at runtime.
- The settings `erlang_node_name` is a reference copy, re-deployed via the seed migration.
- Consumer apps configure You's node name statically in their own config.
- EPMD port 4369 must be exposed between You and consumer app containers.
- The Erlang cookie is encrypted at rest using AES-256-GCM via `Phoenix.Token.encrypt/3`.
  Key derived from `secret_key_base`: compromise of the database alone does not
  expose the cookie.
- Rotating `secret_key_base` invalidates the stored cookie, which must be re-entered.
- Changing the cookie in settings applies immediately via `Node.set_cookie/1`.
  Existing Erlang distribution connections break and consumer apps must reconnect
  with the new cookie.
- The `rel/env.sh.eex` random per-boot bootstrap value is a fallback; the DB
  cookie (decrypted) overrides it during application boot. There is no
  predictable default cookie.
- Adding automatic discovery (libcluster) is deferred to a future ADR.

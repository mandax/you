# Erlang Distribution — Security for Operators

Consumer BEAM apps talk to You over Erlang distribution (see
[ADR 0009](../adr/0009-erlang-distribution-operational.md)). Distribution is
convenient and fast, but its security model is simple and unforgiving: **the
shared cookie is the only gate**. Any node that presents the cookie can run
arbitrary code on every connected node — including You itself. Treat
distribution like a private, mutually-trusted network, not an API.

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| `4369` | TCP | EPMD — Erlang Port Mapper Daemon, node discovery |
| dynamic high ports (typically 4370+) | TCP | Distribution traffic itself |

EPMD answers "which port is node `you@host` listening on?" — the actual
traffic then flows on the dynamic port. Pin it with
`RELEASE_DISTRIBUTION_PORT` if you need a fixed firewall rule, or keep both
sides on the same container network so EPMD can negotiate directly.

## Cookie hygiene

- `RELEASE_COOKIE` (env var) is only a **bootstrap value** so the VM can start
  with distribution enabled. After boot, You reads the `erlang_cookie`
  setting from the database (stored encrypted with a key derived from
  `SECRET_KEY_BASE`) and applies it via `Node.set_cookie/1`. The DB value
  wins.
- Consumer apps don't read You's database — distribute the cookie to them
  out-of-band (shared env var, Kubernetes Secret, etc.). It must match
  exactly on every node.
- **Rotation:** changing the cookie in the admin settings page applies
  immediately and **breaks all existing distribution connections** — in-flight
  `GenServer.call`s fail with `{:error, :unreachable}` until consumers are
  updated. Update consumer apps first, then You, or accept brief downtime.
- Rotating `SECRET_KEY_BASE` invalidates the encrypted cookie in the settings
  table — it must be re-entered.

## Firewall guidance

Only consumer nodes should be able to reach You's distribution ports:

- Allow TCP `4369` and the distribution port(s) **only** from the IPs/networks
  of your consumer app nodes.
- Deny everything else — including the rest of your internal network if the
  consumer set is small and known.
- If consumer apps don't use Erlang distribution at all (OIDC-only
  deployment), don't expose these ports anywhere and consider starting the VM
  with `RELEASE_DISTRIBUTION=none`.

## When NOT to expose distribution

- **Never to the public internet.** Cookie authentication is not designed to
  withstand untrusted networks, and a successful connection is full remote
  code execution.
- **Never to nodes you don't fully control.** A "consumer" operated by a
  third party must use the OIDC/HTTP path instead (see
  [../integration.md](../integration.md)) — there is no partial-trust mode in
  Erlang distribution.
- Never rely on the cookie as an authorization layer between mutually
  suspicious services; it authenticates the node, not the workload.

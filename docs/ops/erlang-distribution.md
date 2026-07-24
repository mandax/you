# Erlang Distribution — Security for Operators

Consumer BEAM apps talk to You over Erlang distribution (see
[ADR 0009](../adr/0009-erlang-distribution-operational.md)). Distribution is
convenient and fast, but its security model is simple and unforgiving: **the
shared cookie is the only gate**. Any node that presents the cookie can run
arbitrary code on every connected node — including You itself. **The trust is
mutual:** You (or anyone who compromises it) can equally run code on every
connected consumer node. Treat distribution like a private, mutually-trusted
network, not an API.

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

## Encrypted transport: use a mesh network (Tailscale / WireGuard)

Distribution traffic is **plaintext by default** — credentials and tokens
cross the wire in the clear. The pragmatic fix is not to encrypt
distribution itself but to put the nodes on an encrypted mesh network:

- **Tailscale / WireGuard** give you authenticated, encrypted node-to-node
  channels with zero OTP configuration. Bind or firewall EPMD and the
  distribution ports to the tailnet interface only, and distribution traffic
  never crosses a network in the clear.
- The alternative is **TLS distribution** (`-proto_dist inet_tls` with
  per-node certificates), which also authenticates nodes by certificate —
  at the cost of issuing, distributing, and rotating certs for every node.
  Even then, a connected node remains fully trusted; TLS only protects the
  wire. See the OTP `ssl` distribution docs if you go this route.

For most deployments a mesh network is the better trade: same
confidentiality, no OTP plumbing.

## When NOT to expose distribution

- **Never to the public internet.** Cookie authentication is not designed to
  withstand untrusted networks, and a successful connection is full remote
  code execution.
- **Never to nodes you don't fully control.** A "consumer" operated by a
  third party must use the OIDC/HTTP path instead (see
  [../integration.md](../integration.md)) — there is no partial-trust mode in
  Erlang distribution.
- **Consumers: never connect to a You instance you don't operate.** The
  trust is mutual — You's operator (or anyone who compromises that node)
  can execute code on your app host and sees all credentials that flow
  through it. Connecting to someone else's IAM over distribution hands them
  your node; use OIDC for that.
- Never rely on the cookie as an authorization layer between mutually
  suspicious services; it authenticates the node, not the workload.

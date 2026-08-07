# Docker: Production Deployment

Run You IAM as a Docker container. Pre-built images are published to
[GitHub Container Registry](https://github.com/mandax/you/pkgs/container/you).

## Pull (recommended)

```bash
docker pull ghcr.io/mandax/you:latest
```

Tagged images follow semver (`v0.1.0`, `v0.2`, etc.).

## Build from source

If you prefer to build yourself:

```bash
git clone https://github.com/mandax/you.git && cd you
docker build -t you:latest .
```

The build is **multi-stage**:
1. **Builder**: compiles the app and creates an Elixir release (includes ERTS)
2. **Runtime**: minimal Alpine image with only the release + SQLite

Source code is **not present** in the final image; only the compiled release is.

## Run

```bash
docker run -d \
  -e DATABASE_PATH=/data/you/prod.db \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=you.example.com \
  -v you-data:/data/you \
  -p 4000:4000 \
  ghcr.io/mandax/you:latest
```

### All environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_PATH` | Yes | (none) | Path to the SQLite database file |
| `SECRET_KEY_BASE` | No | generated | Phoenix secret key. Generated on first boot and persisted to `$(dirname DATABASE_PATH)/secret_key_base` (0600) when unset |
| `JWT_SIGNING_KEY` | No | generated | Ed25519 seed for App JWTs. Generated on first boot and persisted to `$(dirname DATABASE_PATH)/jwt_signing_key` (0600) when unset. Never ephemeral — losing it invalidates every issued token |
| `PHX_HOST` | Yes | (none) | Public hostname (e.g., `you.example.com`) |
| `WEBAUTHN_RP_ID` | No | `PHX_HOST` | The WebAuthn relying-party ID passkeys are bound to. Unset derives it from `PHX_HOST`, matching today's behaviour. Environment-only — never console-editable, same reasoning as `PHX_HOST` — and changing it strands every passkey already registered, in both directions. A host offers passkeys only when it equals this value or is a subdomain of it |
| `SMTP_HOST` | No | (none) | Mail relay. Unset falls back to an in-memory mailbox at `/console/mailbox`; every emailed flow is then undeliverable |
| `YOU_MODE` | No | `multi` | `single` provisions one app from `SINGLE_APP_*` and hides the multi-app surface. See [quickstart](../quickstart.md) |
| `SINGLE_APP_SLUG` | With `YOU_MODE=single` | `app` | The app's client id |
| `SINGLE_APP_NAME` | No | the slug | Display name on the login page |
| `SINGLE_APP_CALLBACK_URL` | With `YOU_MODE=single` | (none) | Where the auth code is delivered |
| `SINGLE_APP_LAUNCH_URL` | No | callback origin | Where "Open <app>" points from `/users/settings` |
| `PORT` | No | `4000` | HTTP port |
| `POOL_SIZE` | No | `10` | Ecto connection pool size |
| `PHX_SERVER` | No | `true` | Set to start the HTTP server |
| `RELEASE_NODE` | No | `you@you.example.com` | Erlang node name (for Erlang distribution) |
| `RELEASE_COOKIE` | No | random per boot | Erlang cookie. When unset a random per-boot value is used (fail closed); the `erlang_cookie` setting in the database overrides it at boot |
| `DNS_CLUSTER_QUERY` | No | (none) | DNS cluster query for distributed Erlang |
| `API_TOKEN` | No | (none) | Seeds the `api_token` setting on first boot. Unset or blank leaves the management API disabled (`403`). The console owns it afterwards |
| `ANALYTICS_SRC` | No | (none) | Seeds `analytics_src`. Plausible-compatible script URL; both this and the domain must be set or nothing is emitted |
| `ANALYTICS_DOMAIN` | No | (none) | Seeds `analytics_domain` |
| `YOU_BUNDLE_PASSWORD_FILE` | No | (none) | Read by `mix you.bundle` / `You.Release.*_bundle`. Path to a file holding the bundle password — the right answer for CI, where a mounted secret beats a string in a job definition |
| `YOU_BUNDLE_PASSWORD` | No | (none) | Same, as a value. Checked after the file. There is deliberately no `--password` flag |

### Volumes

| Mount | Purpose |
|-------|---------|
| `/data/you` | SQLite database, WAL files, and generated secrets (`secret_key_base`, `jwt_signing_key`, `single_app_client_secret`) |
| `/var/log/you` | Audit log files (optional) |

## First-time Setup

### 1. Run migrations

```bash
docker exec <container> bin/migrate
```

### 2. Create an admin user

```bash
docker exec <container> bin/you eval \
  'You.Release.bootstrap_admin("admin@example.com", "your-password")'
```

For non-interactive production use, pass the email and password as arguments.

## Erlang Distribution

Consumer apps communicate with You via Erlang distribution.
All nodes must share the same cookie and distribution must be enabled.

### Required env vars (must match on ALL nodes)

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `RELEASE_DISTRIBUTION` | `name` (via env.sh.eex) | Yes | Must be `name` or `sname`; Erlang distribution is disabled by default |
| `RELEASE_NODE` | `you@HOSTNAME` (via env.sh.eex) | Yes | Node identifier; consumer apps address You by this name |
| `RELEASE_COOKIE` | (none) | **Yes** | Shared secret that **must be identical** on You AND all consumer app nodes |

### How the cookie works

Erlang distribution uses a **cookie-based authentication** model. Two nodes can
communicate only if they present the same cookie.

You manages the cookie through the console settings page (`/console/settings`):

1. The `erlang_cookie` setting is stored in the database
2. At boot, `CookieSync` reads it and applies it via `Node.set_cookie/1`
3. When you change it in settings, it's applied **immediately**
4. The `RELEASE_COOKIE` env var is still supported. When it is unset, a
   random per-boot value is used, so an unconfigured node refuses consumer
   connections (fail closed).

**Consumer apps** must have the same cookie configured on their
side, since they don't read You's database. You must share the cookie value
out-of-band (same env var, same Kubernetes Secret, etc.).

```yaml
# Docker Compose: You's cookie comes from settings (admin panel)
# The consumer app's cookie must match, configured via env var
services:
  you:
    environment:
      RELEASE_DISTRIBUTION: name
      RELEASE_NODE: you@you

  myapp:
    environment:
      RELEASE_DISTRIBUTION: name
      RELEASE_NODE: myapp@myapp
      RELEASE_COOKIE: "${ERLANG_COOKIE}"  # must match You's setting
```

### How consumer apps connect

Consumer apps use the `You.SDK` and need to know You's Erlang node name:

```elixir
# In the consumer app's config/runtime.exs
config :you_sdk, node: String.to_atom(System.get_env("YOU_NODE", "you@you"))
```

### Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| `4369` | TCP | EPMD (Erlang Port Mapper Daemon) for node discovery |
| `4000` | TCP | HTTP (Phoenix web server) |

Erlang distribution also uses **dynamic high ports** (typically 4370+).
In container environments, you may need to set `RELEASE_DISTRIBUTION_PORT`
to pin the port, or run both services on the same Docker network so
EPMD can negotiate directly.

### Settings reference

You's settings table stores `erlang_node_name` and `epmd_port` as a
**reference copy** only. Changing them in the admin panel does NOT
reconfigure the running Erlang VM; you must restart the container with
the matching `RELEASE_NODE` env var.

## Commands

```bash
# Start the server
docker exec <container> bin/server

# Run database migrations
docker exec <container> bin/migrate

# Open an IEx console
docker exec -it <container> bin/you remote

# Run an arbitrary Elixir expression
docker exec <container> bin/you eval 'IO.puts("hello")'

# Check status
docker exec <container> bin/you pid
```

## Building for Production

### With your own config

Create a `config/prod.secret.exs` (not committed) and rebuild:

```bash
# Or set config via environment variables (per runtime.exs)
docker build -t you:latest .
```

### Arm64 / Apple Silicon

The Dockerfile uses `hexpm/elixir:1.19.5-erlang-28.5.0.1-alpine-3.21.7` which supports
both `linux/amd64` and `linux/arm64`. Build natively:

```bash
docker build --platform linux/arm64 -t you:latest .
```

## Security Notes

- The final image contains **no source code**, only the compiled BEAM release
- The release is **self-contained**: it includes ERTS, so no Erlang/Elixir runtime is needed
- SQLite database is stored on a **persistent volume**, so data survives container restarts
- Audit logs should be written to a **volume mount** for persistence

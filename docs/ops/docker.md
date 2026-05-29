# Docker — Production Deployment

Build and run You IAM as a Docker container using the multi-stage `Dockerfile`.

## Build

```bash
docker build -t you:latest .
```

The build is **multi-stage**:
1. **Builder** — compiles the app and creates an Elixir release (includes ERTS)
2. **Runtime** — minimal Alpine image with only the release + SQLite

Source code is **not present** in the final image — only the compiled release.

## Run

### Minimal

```bash
docker run -d \
  -e DATABASE_PATH=/data/you/prod.db \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=you.example.com \
  -v you-data:/data/you \
  -p 4000:4000 \
  you:latest
```

### All environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_PATH` | Yes | — | Path to the SQLite database file |
| `SECRET_KEY_BASE` | Yes | — | Phoenix secret key (`openssl rand -base64 48`) |
| `PHX_HOST` | Yes | — | Public hostname (e.g., `you.example.com`) |
| `PORT` | No | `4000` | HTTP port |
| `POOL_SIZE` | No | `10` | Ecto connection pool size |
| `PHX_SERVER` | No | `true` | Set to start the HTTP server |
| `RELEASE_NODE` | No | `you@you.internal` | Erlang node name (for Erlang distribution) |
| `RELEASE_COOKIE` | No | — | Erlang cookie (required for Erlang distribution) |
| `DNS_CLUSTER_QUERY` | No | — | DNS cluster query for distributed Erlang |

### Volumes

| Mount | Purpose |
|-------|---------|
| `/data/you` | SQLite database and WAL files |
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

Consumer apps (Sockeet, etc.) communicate with You via Erlang distribution.
All nodes must share the same cookie and distribution must be enabled.

### Required env vars (must match on ALL nodes)

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `RELEASE_DISTRIBUTION` | `name` (via env.sh.eex) | Yes | Must be `name` or `sname` — Erlang distribution is disabled by default |
| `RELEASE_NODE` | `you@HOSTNAME` (via env.sh.eex) | Yes | Node identifier — consumer apps address You by this name |
| `RELEASE_COOKIE` | (none) | **Yes** | Shared secret — **must be identical** on You AND all consumer app nodes |

### How the cookie works

Erlang distribution uses a **cookie-based authentication** model. Two nodes can
communicate only if they present the same cookie. This means:

1. You's container must have `RELEASE_COOKIE` set
2. **Every** consumer app container (Sockeet, etc.) must have the **same**
   `RELEASE_COOKIE` value
3. If cookies don't match, Erlang nodes will refuse to connect (silently)

**The cookie is never stored in You's database** — it's a deployment secret
managed by your container orchestration:

```yaml
# Docker Compose example — both services share the same cookie
services:
  you:
    environment:
      RELEASE_DISTRIBUTION: name
      RELEASE_NODE: you@you
      RELEASE_COOKIE: "${ERLANG_COOKIE}"   # same value

  sockeet:
    environment:
      RELEASE_DISTRIBUTION: name
      RELEASE_NODE: sockeet@sockeet
      RELEASE_COOKIE: "${ERLANG_COOKIE}"   # same value
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
| `4369` | TCP | EPMD (Erlang Port Mapper Daemon) — node discovery |
| `4000` | TCP | HTTP (Phoenix web server) |

Erlang distribution also uses **dynamic high ports** (typically 4370+).
In container environments, you may need to set `RELEASE_DISTRIBUTION_PORT`
to pin the port, or run both services on the same Docker network so
EPMD can negotiate directly.

### Settings reference

You's settings table stores `erlang_node_name` and `epmd_port` as a
**reference copy** only. Changing them in the admin panel does NOT
reconfigure the running Erlang VM — you must restart the container with
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

The Dockerfile uses `hexpm/elixir:1.19.5-erlang-29.0.1-alpine-3.21` which supports
both `linux/amd64` and `linux/arm64`. Build natively:

```bash
docker build --platform linux/arm64 -t you:latest .
```

## Security Notes

- The final image contains **no source code** — only the compiled BEAM release
- The release is **self-contained** — includes ERTS, no Erlang/Elixir runtime needed
- SQLite database is stored on a **persistent volume** — data survives container restarts
- Audit logs should be written to a **volume mount** for persistence

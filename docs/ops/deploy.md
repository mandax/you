# Deploy — Production Deployment Guide

How to run You IAM in production: required configuration, mail setup, HTTPS,
database, first admin, and a minimal runbook. For Docker specifics see
[docker.md](docker.md).

## Environment variables

All runtime configuration is read from environment variables in
`config/runtime.exs`. In production, missing required variables abort the boot.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_PATH` | Yes | — | Path to the SQLite database file (e.g. `/data/you/prod.db`) |
| `SECRET_KEY_BASE` | Yes | — | Phoenix secret key. Generate with `mix phx.gen.secret` or `openssl rand -base64 48` |
| `PHX_HOST` | Yes | `example.com` | Public hostname. Drives generated URLs (magic links, OIDC discovery, WebAuthn origin) |
| `PORT` | No | `4000` | HTTP port the app listens on |
| `POOL_SIZE` | No | `10` | Ecto connection pool size |
| `PHX_SERVER` | No | — | Set to `true` to start the HTTP server (already set in the Docker image) |
| `RELEASE_NODE` | No | `you@$HOSTNAME` | Erlang node name (Erlang distribution) |
| `RELEASE_COOKIE` | No | `bootstrap_temp` | Erlang cookie bootstrap value — the `erlang_cookie` setting in the database overrides it at boot (see [erlang-distribution.md](erlang-distribution.md)) |
| `DNS_CLUSTER_QUERY` | No | — | DNS cluster query for distributed Erlang |

Set `PHX_HOST` to the hostname users actually reach You on. It is used to build
the OIDC issuer URL and the WebAuthn origin (`https://<PHX_HOST>`), so a wrong
value breaks magic-link emails, discovery documents, and passkeys.

## Mail (SMTP)

You sends transactional email (magic links, confirmation) via Swoosh. In
production, point it at your SMTP relay:

| Variable | Description |
|----------|-------------|
| `SMTP_HOST` | SMTP server hostname |
| `SMTP_PORT` | SMTP port (typically `587` for STARTTLS, `465` for TLS) |
| `SMTP_USERNAME` | SMTP auth username |
| `SMTP_PASSWORD` | SMTP auth password |
| `MAIL_FROM` | Sender address — default `no-reply@<PHX_HOST>` |

`SMTP_HOST` is required in production (boot aborts without it). `SMTP_USERNAME`
and `SMTP_PASSWORD` are optional as a pair — omit both for an unauthenticated
relay. TLS (STARTTLS) is always enforced. Without a working SMTP relay,
magic-link and confirmation emails are not delivered. Password and passkey
logins still work.

## JWT signing keys

Access tokens and id_tokens are Ed25519-signed JWTs. Without configuration You
generates an **ephemeral key per boot** — every token dies on restart, and
multiple replicas would each sign with a different key. Set a persistent key:

| Variable | Required | Description |
|----------|----------|-------------|
| `JWT_SIGNING_KEY` | Recommended | base64url-encoded 32-byte Ed25519 seed. Generate: `mix run -e ':crypto.strong_rand_bytes(32) \|> Base.url_encode64(padding: false) \|> IO.puts()'` |
| `JWT_KEY_ID` | No | Key id stamped into token headers and JWKS. Default `you-ed25519-v1` |
| `JWT_PREVIOUS_KEYS` | No | Comma-separated `kid:seed` pairs kept for verification only, during rotation |

Rotation: generate a new seed, move the old `kid:seed` pair into
`JWT_PREVIOUS_KEYS`, point `JWT_KEY_ID`/`JWT_SIGNING_KEY` at the new key, and
drop the old pair once every token it signed has expired
(`jwt_expiry_hours` setting). Consumers pick up new keys automatically from
`/.well-known/jwks.json`.

## HTTPS

Run You **behind a reverse proxy** (nginx, Caddy, Traefik, a load balancer)
that terminates TLS. The app itself listens on plain HTTP (`PORT`, default
`4000`) and binds to all interfaces in production.

The endpoint is compiled with `force_ssl` using
`rewrite_on: [:x_forwarded_proto]` — so:

- The proxy **must** set `X-Forwarded-Proto: https` on forwarded requests.
- HTTP requests are redirected to HTTPS and HSTS is set automatically.
- `localhost` / `127.0.0.1` are excluded from the redirect (health checks).

`config/runtime.exs` sets the endpoint URL to `https://<PHX_HOST>:443`, so all
generated links are HTTPS regardless of the internal port.

## Database

You uses a single SQLite file at `DATABASE_PATH`. The file, its WAL, and its
backups are the entire persistent state of the system.

- Put `DATABASE_PATH` on persistent storage (a volume, not container-local
  disk).
- See [backup.md](backup.md) for the backup script, retention, and restore
  procedure.

## First admin

You ships with no users. Bootstrap the first admin before inviting anyone else.

From a checkout (development):

```bash
mix you.bootstrap_admin
```

The task prompts for email and password interactively and is idempotent.

From a release (production, no Mix):

```bash
bin/you eval 'You.Release.bootstrap_admin("admin@example.com", "your-password")'
```

`You.Release.bootstrap_admin/2` runs migrations first, then creates the admin.
With Docker:

```bash
docker exec <container> bin/you eval \
  'You.Release.bootstrap_admin("admin@example.com", "your-password")'
```

## Runbook

### Start

```bash
# Release
bin/you start        # daemon
bin/server           # foreground with PHX_SERVER=true

# Docker
docker run -d --name you \
  -e DATABASE_PATH=/data/you/prod.db \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=you.example.com \
  -v you-data:/data/you \
  -p 4000:4000 \
  you:latest
```

### Migrate

```bash
bin/migrate
# or explicitly
bin/you eval 'You.Release.migrate()'
```

Run migrations after every upgrade, before (or as part of) starting the new
version. `bootstrap_admin/2` also runs migrations.

### Logs

The release logs to stdout — collect it with your container runtime or process
manager. Audit events are additionally written as JSONL under `/var/log/you`;
mount that directory to persist them, and include it in backups (see
[backup.md](backup.md)).

### Inspect a running node

```bash
bin/you pid          # is it up?
bin/you remote       # remote IEx console
bin/you eval 'You.Release.migrate()'
```

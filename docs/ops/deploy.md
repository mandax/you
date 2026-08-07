# Deploy: Production Deployment Guide

How to run You IAM in production: required configuration, mail setup, HTTPS,
database, first admin, and a minimal runbook. For Docker specifics see
[docker.md](docker.md).

## Environment variables

All runtime configuration is read from environment variables in
`config/runtime.exs`. In production, missing required variables abort the boot.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_PATH` | Yes | (none) | Path to the SQLite database file (e.g. `/data/you/prod.db`) |
| `SECRET_KEY_BASE` | No | generated | Phoenix secret key. When unset it is generated on first boot and persisted to `$(dirname DATABASE_PATH)/secret_key_base` with mode 0600. Set it explicitly if you manage secrets outside the data volume |
| `PHX_HOST` | Yes | `example.com` | Public hostname. Drives generated URLs (magic links, OIDC discovery, WebAuthn origin) |
| `PHX_SCHEME` | No | `https` | Scheme for generated URLs. Leave unset behind Cloudflare or any TLS proxy. `http` is for localhost or a private network; it also drops the `secure` flag from the session cookie, since a `secure` cookie is never sent over plaintext. Anything else aborts the boot |
| `PHX_URL_PORT` | No | `443`/`80` | Port in generated URLs, when the public port is not the scheme's default |
| `PORT` | No | `4000` | HTTP port the app listens on |
| `POOL_SIZE` | No | `10` | Ecto connection pool size |
| `PHX_SERVER` | No | (none) | Set to `true` to start the HTTP server (already set in the Docker image) |
| `RELEASE_NODE` | No | `you@$HOSTNAME` | Erlang node name (Erlang distribution) |
| `RELEASE_COOKIE` | No | random per boot | Erlang cookie bootstrap value: a random value when unset (fail closed), overridden at boot by the `erlang_cookie` setting in the database (see [erlang-distribution.md](erlang-distribution.md)) |
| `DNS_CLUSTER_QUERY` | No | (none) | DNS cluster query for distributed Erlang |
| `WEBAUTHN_RP_ID` | No | derived from `PHX_HOST` | The WebAuthn relying-party id passkeys are bound to. Environment-only — no console path can set it. Unset reproduces the value derived from `PHX_HOST` today, so a single-host deployment is unchanged, but from then on `PHX_HOST` and the RP ID can move independently: changing this value (or, while it stays unset, changing `PHX_HOST`) strands every passkey already registered, in both directions. A host offers passkeys only when it equals `WEBAUTHN_RP_ID` or is a subdomain of it |

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
| `MAIL_FROM` | Sender address, default `no-reply@<PHX_HOST>` |

`SMTP_USERNAME` and `SMTP_PASSWORD` are optional as a pair: omit both for an
unauthenticated relay. TLS (STARTTLS) is always enforced.

Without `SMTP_HOST` the boot does not abort: mail is kept in an in-memory
mailbox that admins can read at `/console/mailbox`, and the console overview
says the instance is not production ready. That exists so an evaluation can
exercise magic links and email 2FA, not so an install can run without mail —
the mailbox is lost on restart and no user ever receives anything. Password and
passkey logins still work either way.

## JWT signing keys

Access tokens and id_tokens are Ed25519-signed JWTs. When `JWT_SIGNING_KEY` is
unset You generates a key on first boot and persists it to
`$(dirname DATABASE_PATH)/jwt_signing_key` (mode 0600), so tokens survive
restarts. Set it explicitly when you manage secrets outside the data volume, or
when several replicas must sign with the same key without sharing a volume:

| Variable | Required | Description |
|----------|----------|-------------|
| `JWT_SIGNING_KEY` | No | base64url-encoded 32-byte Ed25519 seed. Generate: `mix run -e ':crypto.strong_rand_bytes(32) \|> Base.url_encode64(padding: false) \|> IO.puts()'` |
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
`rewrite_on: [:x_forwarded_proto]`, so:

- The proxy **must** set `X-Forwarded-Proto: https` on forwarded requests.
- HTTP requests are redirected to HTTPS and HSTS is set automatically.
- `localhost` / `127.0.0.1` are excluded from the redirect (health checks).

`config/runtime.exs` sets the endpoint URL from `PHX_SCHEME`/`PHX_HOST`
(`https://<PHX_HOST>:443` unless you say otherwise), so all generated links use
that scheme regardless of the internal port, and the session cookie is marked
`secure` whenever the scheme is https.

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
  ghcr.io/mandax/you:latest
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

The release logs to stdout; collect it with your container runtime or process
manager. Audit events are additionally written as JSONL under `/var/log/you`;
mount that directory to persist them, and include it in backups (see
[backup.md](backup.md)).

### Inspect a running node

```bash
bin/you pid          # is it up?
bin/you remote       # remote IEx console
bin/you eval 'You.Release.migrate()'
```

# Quickstart: one app, five minutes

This is the single-app install: `docker compose up`, one app provisioned for
you and managed from the console, and a working login page with passwords,
magic links, passkeys, 2FA and a user portal.

Running an identity provider for several apps instead? Read
[ops/deploy.md](ops/deploy.md) — this guide provisions exactly one app and
hides the registry.

Nothing here is a one-way door. Single-app mode is a runtime flag over the same
schema: dropping `YOU_MODE` and restarting gives you the full multi-app console
with your users, roles and consents intact.

> **Upgrading an existing install rather than starting one?** Read
> [CHANGELOG.md](../CHANGELOG.md) first. Some releases change authentication
> behaviour or need operator action, and `docker compose pull` crosses every
> version between yours and the newest in one step.

## 1. Configure

```sh
git clone https://github.com/mandax/you.git && cd you
cp .env.example .env
```

Edit `.env`. Only `PHX_HOST` genuinely has to be right before first boot; the
app's details seed the console and can be changed there afterwards.

| Variable | What it is |
| --- | --- |
| `PHX_HOST` | The hostname users reach You on, e.g. `id.example.com`. Magic links, OIDC discovery and passkeys are all built from it. |
| `SINGLE_APP_NAME` | What the login page calls your app. |
| `SINGLE_APP_CALLBACK_URL` | Where You redirects after a successful login, with `?code=…`. Optional — leave it blank until your app has a callback route, then set it in the console. |
| `SINGLE_APP_LAUNCH_URL` | Where "Open <app>" points from the account page at `/users/settings`. Optional — defaults to the origin of the callback URL. |
| `SMTP_*` | See [step 4](#4-configure-email). |

You do not set `SECRET_KEY_BASE` or `JWT_SIGNING_KEY`. Both are generated on
first boot and persisted to the `you-data` volume with `0600`. That is on
purpose: a secret shipped in a compose file is a secret shared by every install
of You in the world, and anyone holding it can forge tokens against any of
them.

## 2. Start

```sh
docker compose up -d
docker compose logs -f you
```

The compose file's command runs the migrations before starting the release
(`bin/migrate && bin/you start`), so the first boot brings up the schema,
generates its secrets, and provisions your app in one go. A multi-app
deployment migrates as a deliberate step instead — see
[ops/docker.md](ops/docker.md).

The app's client secret — needed only for the headless auth API — is written to
`/data/you/single_app_client_secret` inside the volume:

```sh
docker compose exec you cat /data/you/single_app_client_secret
```

The compose file overrides the image's entrypoint to migrate first, so reach
for `docker compose exec` (against the running container) rather than
`docker compose run`, which would need `--entrypoint /app/bin/you`.

## 3. Put a reverse proxy in front

You listens on plain HTTP on `127.0.0.1:4000` and expects TLS to be terminated
in front of it — Cloudflare, Caddy, nginx, a load balancer, whichever you run.
This is not optional: You marks its session cookie `secure`, `force_ssl`
redirects plaintext requests and sets HSTS, callback URLs are `https`, and
passkeys refuse to work over an insecure origin.

Caddy, which handles certificates for you:

```
id.example.com {
    reverse_proxy 127.0.0.1:4000
}
```

nginx, with certificates from certbot:

```nginx
server {
    server_name id.example.com;
    listen 443 ssl;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        # LiveView (the console) needs WebSocket upgrades.
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

`X-Forwarded-Proto` is load-bearing: You uses it to know the request arrived
over TLS.

## 4. Configure email

Magic links, email 2FA, address confirmation and password reset all send mail.
With no `SMTP_HOST`, You does not fail — it keeps mail in an in-memory mailbox
readable by admins at `/console/mailbox`, and the console says the install is
not production ready. That is enough to evaluate every flow, and not enough to
run one: the mailbox is lost on restart and no user ever receives anything.

Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAIL_FROM`
in `.env`, then `docker compose up -d` to restart. The warning on the console
overview disappears when mail is actually going out.

## 5. Create the first admin

```sh
docker compose exec you bin/you eval \
  'You.Release.bootstrap_admin("you@example.com", "a-long-password")'
```

Sign in at `https://id.example.com/users/log-in`, and the console is at
`/console`. Only an existing admin can promote another.

## 6. Wire up your app

Send users to You, and exchange the code that comes back:

```
https://id.example.com/users/log-in?callback_url=https://app.example.com/auth/callback
```

After signing in, You redirects to your callback with `?code=…`. There is no
consent screen: the app provisioned for single-app mode is flagged
`first_party`, so the user is signing in rather than authorizing a third
party. (Consent is still recorded, so a later mode flip leaves no gap.)

Exchange the code for a JWT with whichever integration fits:

- **Elixir over Erlang distribution** — `You.SDK.exchange_code(code)`. See
  [integration.md](integration.md) and
  [ops/erlang-distribution.md](ops/erlang-distribution.md).
- **Anything else, over OIDC** — `POST /oauth/token` with the code plus your
  client credentials (or a PKCE verifier, for a browser or mobile client),
  verifying against `/.well-known/jwks.json`. See
  [integration.md](integration.md).

## 7. Back it up

Everything is in the `you-data` volume: the SQLite database, the WAL, and the
generated secrets. Losing it is losing every account, and losing the secrets
alone invalidates every issued token. See [ops/backup.md](ops/backup.md) and
[ops/restore.md](ops/restore.md).

```sh
docker compose exec you sqlite3 /data/you/you.db ".backup '/data/you/backup.db'"
docker compose cp you:/data/you/backup.db ./you-backup.db
```

## Growing out of single-app mode

Remove `YOU_MODE` (and the `SINGLE_APP_*` variables) from `.env` and restart.
The apps registry reappears in the console with your app already in it, and
the account hub goes back to listing every app a user has connected. The
consent screen still does not appear for the app provisioned here — it stays
`first_party` — but any other app you register in the console will get one,
same as it would have in single-app mode. No migration, no reinstall — the
schema was never different.

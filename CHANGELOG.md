# Changelog

Notable changes per release, with anything that needs operator action called
out first. The GitHub [Releases](https://github.com/mandax/you/releases) page
carries the same notes in fuller prose; this file exists so they travel with
the source, including into an air-gapped checkout.

**Before upgrading**, read the entry for every version between yours and the
one you are moving to — not only the newest. `docker compose pull` crosses all
of them at once.

## Unreleased

### Requires your attention

- **App slugs are now validated.** `slug` doubles as the OAuth `client_id`,
  a segment of every authorize URL, and half of the role-resolution key, but
  was checked for uniqueness only — `foo.bar`, `My App!` and `_x` were all
  legal. It is now held to lowercase letters, digits, hyphens and
  underscores, at most 64 characters. A row written before this validation
  existed keeps its non-conforming slug until something touches the slug
  itself, but from here on: renaming that app fails validation, and **a
  bundle exported from a pre-validation instance can fail to import** if it
  carries a non-conforming slug. Run `mix you.audit_slugs`
  (`bin/you eval 'You.Release.audit_slugs()'` in a release) right after
  upgrading, before renaming anything, to find out which apps are affected.

## 0.4.0 — Per-app context, invitations, guests, and auth hardening

### Requires your attention

- **A second factor now applies to every sign-in method.** Only the password
  path checked it, so an account with an authenticator enrolled could be
  signed into with a magic link, or through any enabled identity provider,
  without meeting it. Since 0.3.0 made SMTP settings-writable, anyone able to
  change settings could redirect mail and use the magic-link path to bypass
  2FA on any account.
  - **Users** with 2FA enrolled are now challenged after clicking a magic link
    or returning from a provider.
  - **Headless consumers**: `POST /api/auth/login` enforced TOTP but let an
    email-2FA account straight through. It now sends the code and answers
    `401 mfa_required` until the client resubmits with `email_2fa_code`, as it
    already did for `totp_code`. A first-party app whose users have email 2FA
    enabled must handle that round trip.
  - Passkeys are deliberately outside this gate.
- **The OIDC `id_token` now carries the per-app role.** It was built without
  the app it was for, so with the `roles` scope it fell back to the account's
  global admin flag: an `id_token` said `role: "admin"` for a You admin who is
  an ordinary user of the app that asked, while the access token in the same
  response said `"user"`. **A consumer that gates on `id_token.role` will see
  different values for accounts that are You admins.** The access token was
  always correct and is unchanged.
- **Three config keys moved to settings.** `config :you, :mode`,
  `config :you, :api_token` and `config :you, :analytics` no longer exist.
  `YOU_MODE`, `API_TOKEN`, `ANALYTICS_SRC` and `ANALYTICS_DOMAIN` seed the
  corresponding settings on first boot and the console owns them afterwards.
  If you set these in a config file rather than the environment, move them.

No migration is destructive and all five are reversible; an existing instance
upgrades without operator action beyond the above.

### Added

- **Per-app token lifetimes.** `jwt_expiry_hours` and `code_expiry_minutes`
  become per-app overrides, `null` following the instance. Bounded at 720
  hours and 60 minutes. `session_expiry_hours` stays instance-wide — it is the
  You portal cookie, one per browser across every app.
- **Custom JWT claims per app.** An app declares static claims — tenant id,
  plan, feature flags — merged into every token issued for it. Additive only:
  reserved names are refused at write time and filtered again at build time,
  so an app cannot rewrite the identity, the role a consumer authorizes on, or
  its own expiry. Capped at 32 claims and 1024 bytes.
- **Invitations.** An admin invites by email from an app's Members tab with a
  role, and can withdraw what is pending. See `docs/authkit.md`.
- **Guest accounts.** A first-party app can create an anonymous account and
  upgrade it in place, keeping the same user id. Off by default
  (`feature_guest_login`). See `docs/authkit.md`.
- **Editable transactional emails.** The six templates are editable in the
  console; only overrides are stored, so an untouched template keeps tracking
  the default. Overrides travel in configuration bundles.
- **Configuration bundles over HTTP and the command line.** Three POST
  endpoints under `/api/v1/config/bundle`, plus `mix you.bundle` and
  `You.Release.export_bundle/2`. The password never comes from argv — it
  resolves from `YOU_BUNDLE_PASSWORD_FILE`, then `YOU_BUNDLE_PASSWORD`, then a
  prompt. See `docs/api.md`.
- **Cluster-wide cache invalidation** over PubSub, so a settings or app change
  on one node reaches the others rather than waiting for a restart.

### Changed

- Sessions on the account page group by the sign-in they came from. A You
  session is still one cookie across every app; the page says so rather than
  implying per-app revocation.
- Single mode drops the app dimension from the roles UI, and its account area
  is `/users/settings` — which now honours `SINGLE_APP_LAUNCH_URL` with an
  "Open &lt;app&gt;" button. Every entry point goes there directly instead of
  redirecting through `/users/dashboard`.
- Configuration bundles now carry email templates as well as settings, apps,
  identity providers and webhook endpoints. Bundle exports contain
  operator-authored email copy; check what yours say before sharing one.

### Fixed

- TOTP logins emitted no audit event, though the event name was already wired
  into the handler, the streamer and the webhook surface.
- `token:refresh`, `user.registered` and `user.anonymized` were emitted but
  never written to the durable audit log.
- Invitations are audited at all three points — issued, withdrawn, accepted.
- JTI blocklist retention is measured against the longest lifetime any app can
  produce. On the instance default alone it would drop a revocation while a
  longer-lived token carrying that JTI was still valid, and a revoked token
  would start working again.
- An authorization code refused on its app's clock is now spent rather than
  left for a second attempt.
- A whitespace-only `api_token` disables the management API instead of
  becoming a credential nobody can see.
- `enable_totp/2` returned the pre-update user, so callers saw
  `totp_enabled: false` on a user who had just enabled it.

### Removed

- The organizations model, already dropped in 0.3.0, is now also gone from the
  documented domain. There is no grouping of users above the App; see
  **Tenant** in `CONTEXT.md` for the criteria under which one would return.

## 0.3.0 and earlier

See the [Releases](https://github.com/mandax/you/releases) page. 0.3.0 carries
a breaking change of its own: `POST /oauth/token` began requiring client
authentication or PKCE.

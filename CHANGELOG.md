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

- **The WebAuthn relying-party ID is now pinned, not derived per request.**
  `config :wax_, rp_id: :auto` derived the RP ID from the request host, which
  is fine on one hostname but would silently mint a different RP ID per host
  once You serves several — stranding every passkey a user registered on a
  different one. `WEBAUTHN_RP_ID` now fixes it explicitly. Unset reproduces
  today's derived value exactly, so a single-host deployment is unchanged. It
  is environment-only, like `PHX_HOST` — no console path can set it — and
  **changing it strands every passkey already registered, in both
  directions**: an existing credential's RP ID no longer matches, and a
  credential registered under the new RP ID is not recognized if you change
  it back. Treat it as a deployment operation with a maintenance window, not
  a setting to toggle. A host only offers passkeys when it equals
  `WEBAUTHN_RP_ID` or is a subdomain of it; other hosts hide the passkey
  option and fall back to the app's other enabled sign-in methods.
- **App slugs are now validated, and `new` is reserved.** `slug` doubles as
  the OAuth `client_id`, a segment of every authorize URL, and half of the
  role-resolution key, but was checked for uniqueness only — `foo.bar`, `My
  App!` and `Slug With Spaces` were all legal. It is now held to lowercase
  letters, digits, hyphens and underscores, at most 64 characters, and `new`
  is refused outright — `/console/apps/new` (below) claims that address for
  app registration ahead of `/console/apps/:slug`. A row written before
  either rule existed keeps its slug until something touches the slug
  itself, but from here on: renaming that app fails validation, **a
  configuration bundle exported from a pre-validation instance silently
  skips such an app on import** — the import reports success with an app
  count one short rather than raising, so check the count against what you
  exported — and, specifically for a legacy app slugged `new`,
  `/console/apps/new` now resolves to the registration page instead of it,
  so it becomes unreachable from the console until renamed. Run `mix
  you.audit_slugs` (`bin/you eval 'You.Release.audit_slugs()'` in a
  release) right after upgrading, before renaming anything, to find out
  which apps are affected.
- **Registering an app moved off the apps list into its own page,**
  `/console/apps/new`. The old dialog minted a client secret shown exactly
  once, and a dialog that closes on a stray click was a bad place for the
  only copy of a credential. Nothing about the fields collected changed;
  only where you go to fill them in — the apps list's "New app" button
  still starts it, it just navigates now instead of opening a dialog.
- **Console sections and tabs are now addressed by path, not query string.**
  `/console?view=settings&tab=mail` is now `/console/settings/mail`, and
  `/console/apps/solo?tab=members` is now `/console/apps/solo/members`. Old
  links in either shape — a bookmark, a link in your own docs — still work
  for this release: they redirect (302) to the path form. That redirect is
  temporary; update any saved links to the path form before the next release
  removes it.
- **An unknown console section now 404s instead of silently showing the
  overview.** `/console/not-a-real-section` used to render the overview at
  200 — there was no path to be wrong about before this release, only a
  query param that could name nothing. A stale link to a section your
  instance no longer has (a feature you turned off, a mode you left) now
  answers honestly rather than looking like it worked.
- **The `login:attempt` and `login:totp` audit events gained a
  `request_host_claimed` field, including on the copies streamed to your
  configured webhooks.** It is the `Host` header as the client sent it,
  recorded unvalidated for forensics — not the (allowlisted) host any link
  was actually built with. If you consume these webhook events, expect the
  new field in the payload.

### Added

- **The Emails section is now tabbed, one template per tab,** addressed at
  `/console/emails/:tab` — the same standard `/console/settings/:tab` and
  `/console/apps/:slug/:tab` already follow. It used to render all six
  templates as stacked forms on one scrolling page; now only the template
  you're looking at is on screen, and each keeps its own default badge and
  "Reset to default" action. Tab labels and order still come straight from
  `EmailTemplates.definitions/0`, so a new template gets a tab automatically.
- **Email links follow the host a flow started on, when that host is one
  You knows about.** Magic link, confirmation, password reset, email-change
  and invitation links now build against an allowlisted request host
  instead of always the instance-wide canonical host. Today the allowlist
  is exactly the canonical host, so this changes nothing you'll see yet —
  it's the groundwork for per-app hostnames. A request host that is *not*
  allowlisted (a forged `Host` header, for instance) falls back to
  canonical rather than being used.
- **Social login's OIDC `state` no longer trusts the session — it's bound to
  the browser with a dedicated cookie.** The IdP round trip used to pin its
  CSRF check to the session that started it, which per-app hostnames would
  have broken outright (login starts on an app host, the IdP returns to
  canonical, a different session) and an earlier design for fixing that would
  have quietly dropped the CSRF defence to restore functionality: a signed,
  self-contained `state` proves You minted it, but proves nothing about which
  browser is presenting it back. `/auth/:provider` now hands the IdP an
  opaque `state` keyed to a single-use, short-lived, hashed-at-rest flow
  record (new `federated_login_flows` table, modelled on the existing
  auth-code pattern) and sets a narrowly-scoped, HttpOnly binding cookie; the
  callback refuses unless that cookie's hash matches what's on the record. A
  missing, tampered, replayed, expired, or wrong-browser `state` is refused
  identically, and audited identically to any other failed login attempt.
  Nothing you do changes: social login on the canonical host behaves exactly
  as before. Ground-laying for #121 — an app-host social button will link to
  canonical carrying a short-lived signed `ctx` instead of relying on a
  shared session, which `/auth/:provider` already accepts.

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

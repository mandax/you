# You: Identity and Access Management

Cross-app identity, authentication, authorization, and user settings platform. Every service delegates user management to You.

## Language

**User**:
A person with an account. Has an email, password hash, and optional second factors. A user's access is `(app_slug, user_id) → role_name` and nothing else — there is no grouping above the App (see **Tenant**). May be a [[Guest]]: an account with no credentials yet.
_Avoid_: Account, member

**Admin**:
A User with `is_admin = true`. Gates access to You's admin panel (`/admin`) and instance configuration. Bootstrap via `mix you.bootstrap_admin`. Only an existing admin can promote others.
_Avoid_: Superuser, operator, root

**You Session**:
The browser cookie on you.example.com that proves the user authenticated with You's portal. Database-backed via `users_tokens` (context: "session"). Used to skip the login form on subsequent app authorization flows. Separate from any app JWT: signing out of You does not invalidate app JWTs.
_Avoid_: Auth token, login cookie, global session

**App JWT**:
A per-app credential issued to a specific service. Carries `sub` (user ID), `email`, `app` (which app it's for), `role`, `jti`, `iat`, `exp`. Obtained by exchanging an auth code. Revocable individually via the JTI blocklist.

How long it lives is the app's decision (`jwt_expiry_hours` on the app row), falling back to the instance setting when the app has not pinned one.

**Custom claim**: a static value an app declares in `custom_claims` and You merges into every JWT it issues for that app — a tenant id, a plan, feature flags — so the app reads them from the token instead of a second round-trip. Additive only: the claims above are refused as names and applied on top regardless, so an app can never rewrite the identity, the role a consumer authorizes on, or its own expiry. Scalars and flat lists only; anything with a shape belongs behind userinfo.
_Avoid_: Session token, bearer token, access token

**Role**:
A named set of permissions scoped to a specific app. Example: `(myapp, user-42) → admin`. Roles are always `(app_slug, user_id) → role_name`, never global. Each app has a `default_role` (`"user"` by default) that unassigned users resolve to — a fallback for users who have no explicit tuple.
_Avoid_: Permission, scope, privilege

**App**:
A service that integrates with You for authentication. Each app has an API key for server-to-server communication and a configured set of allowed roles.
_Avoid_: Service, client, integration

**Identity Provider**:
An upstream OIDC or non-OIDC service (Google, Microsoft, GitHub, Discord, etc.) that users can authenticate through. Each provider has its own row in the `identity_providers` table with an encrypted `client_secret`, editable at runtime rather than through config. Providers were migrated from `config :you, :oidc_providers` (which is still seeded on boot for backward compatibility). Non-OIDC providers (GitHub, Discord) route through dedicated adapters instead of the generic userinfo fetch.
_Avoid_: IdP, connection, social provider, SSO provider

"Social login" is the *method* a user picks on the login page (one of password, magic link, passkey, social); an Identity Provider is the upstream service behind it. "OIDC provider" narrows to the subset that speaks OIDC, so it is wrong for GitHub and Discord — use it only where the OIDC-ness is the point (`oidc_providers`, `feature_social_login`, `FederatedAuthController` predate this entry and keep their names).

**Tenant** (deliberately absent):
There is no grouping of users above the App. An `organizations` table and console screen existed briefly and were removed: they carried no JWT claim, took no part in role resolution, and gated nothing, so membership meant only that two users appeared in the same list.

The App is the isolation boundary. A user's access is `(app_slug, user_id) → role_name` and nothing else; a consumer app that needs to scope its own data by customer holds that in its own schema. Reintroduce a tenant only for the case that actually requires one: two customer companies signing in through You to the same app deployment, needing their data kept apart. That means an `org` claim in the App JWT and a rule for which tenant a session is acting for — decide both before adding a table, since the claim is a contract that consumer apps will depend on.

Billing follows the same reasoning: per-team quotas and plans need a tenant to hang off, so they are out of scope until one exists.
_Avoid_: Organization, workspace, group, team

**API Key** (machine-to-machine):
A Bearer token used by apps to call You's internal endpoints (token validation, user lookup). Not to be confused with an app's own API keys (e.g., `sk_` keys for content extraction).
_Avoid_: Token, secret, credential

**Two-Factor Authentication (2FA)**:
An optional second factor on login using TOTP (time-based one-time passwords) or a code emailed after the first factor. Recovery codes (8 single-use bcrypt-hashed codes) are generated at TOTP setup as a fallback.

A second factor belongs to the *account*, not to the method that proved the first one. Every first factor meets it: password, magic link, and any identity provider all pass through `YouWeb.SecondFactor` before an authorization code is issued, and the headless grant refuses with `mfa_required` until the client resubmits with `totp_code` or `email_2fa_code`. Until #112 only the password path checked, which made a magic link a way around an enrolled authenticator.

Passkeys are the exception: a passkey is already a possession factor with user verification, so it stands alone rather than being a first factor awaiting a second.
_Avoid_: MFA, two-step verification

**Guest**:
An account with `is_guest` set, a placeholder address at `anonymous.you` that receives no mail, and no password — created by a first-party app so it can hold state for someone before they sign up. Its JWT carries `guest: true`; a real account carries no `guest` claim at all, and `guest` is a reserved claim name so an app cannot forge one.

Upgrading sets a real email and password on **the same row**, so the user id a consumer app has already written into its own schema does not change. That is the whole feature: without it the app has two identities to merge.

A guest has no login — the token issued at creation is the only way back to that identity. Guests never upgraded are deleted after 30 days. Off by default (`feature_guest_login`): it mints user rows on request.
_Avoid_: Anonymous user, temp account, pre-auth session

**Invitation**:
An admin-issued offer for a named email to join an app, optionally with a role. The only way to onboard one person deliberately — registration is self-service, and SCIM is a push from an upstream directory. Emailed as a single-use link, stored as a SHA-256 hash, valid 7 days.

Accepting proves control of the mailbox, so it is treated exactly like a [[Magic Link]]: it confirms the account (creating a passwordless one if there is none) and signs the user in through `YouWeb.SecondFactor`, so an enrolled second factor is still met. What the invitation adds on top is the role. Accepting is a POST, not the GET that opens the link — a mail client prefetching a URL must not spend a single-use invitation.
_Avoid_: Invite code, signup link, referral

**Email Template**:
The copy of one of the five transactional emails You sends (magic link, confirmation, password reset, email change, 2FA code). Only *overrides* are stored: a template nobody has edited has no row and uses the copy compiled into `You.EmailTemplates`, so an instance that never opens the screen keeps picking up improvements to the default wording, and "reset to default" is a delete. Bodies interpolate `{{name}}` placeholders by string replacement, never evaluation; the ones a template cannot do without (`url` in a magic link, `code` in a 2FA email) are required by the changeset.
_Avoid_: Email layout, mailer template, notification

**Magic Link**:
A passwordless login flow. The user enters their email, You sends a short-lived signed link (15 min), and clicking it exchanges the link token for a JWT. Single-use, consumed on first click. A *first* factor, not a login: an account with a second factor enrolled still meets it after the link is clicked.
_Avoid_: Passwordless login, email auth, one-time link

**Authorization Code**:
A single-use, short-lived (5 min) opaque string exchanged for an App JWT. Generated by You after successful authentication + optional 2FA. Sent via redirect URL callback. SHA-256 hashed in `users_tokens` (context: "oauth_code"). The app calls `You.SDK.exchange_code(code)` over Erlang distribution to obtain the JWT.
_Avoid_: Auth token, one-time code, magic link

**SDK** (`You.SDK`):
The official library for integrating apps with You. Apps add it as a path or Hex dependency. Provides functions that call You's `You.IAM.Server` via Erlang distribution. Handles node resolution, timeout, and returns `{:error, :unreachable}` when You is down.
_Avoid_: HTTP client, REST wrapper, direct GenServer calls

**Erlang Distribution**:
The communication channel between You and apps. Connected BEAM nodes exchange process messages. You registers `You.IAM.Server`, a GenServer that handles `{:verify_token, jwt}`, `{:exchange_code, code}`, `{:get_user, user_id}`, `{:revoke_token, jwt}`. Apps use `You.SDK` which wraps these calls.
_Avoid_: RPC, REST, node coupling

**Grant Scope**:
A declared permission an app requests during authorization. Controls what claims go into the App JWT. Values: `email` (user_id + email), `profile` (adds name, avatar), `roles` (adds role assignments). The app passes `scope` in the redirect URL; can only self-limit, never escalate. 
_Avoid_: Permission, claim, data access level

**Consent**:
A record that a user authorized an app with specific grant scopes. Stored in the `consents` table. Checked at auth code exchange time; expired or missing consent means the user must re-authorize. Expires alongside the App JWT.
_Avoid_: Authorization grant, permission record, approval

**Anonymization**:
The LGPD-compliant deletion method: personal fields (email, password hash, TOTP secret) are nulled or replaced with redacted values. The user row stays for referential integrity with app caches. No login possible after anonymization.
_Avoid_: Hard delete, cascade delete, account removal

**IAM Token Cache** (`iam_tokens` table in each app, optional):
Lightweight local cache stored in each app's database. Stores `you_user_id`, username, email, role, and last validated timestamp. Used for display and graceful degradation when You is unreachable.
_Avoid_: User table, user cache, auth table

## Context Map

You is the center of a hub-and-spoke architecture:

```
You ──── auth, users, roles, billing, settings
   │
   ├── myapp ─── validates You JWTs via Erlang distribution
   └── (future app) ─── same pattern

Apps redirect users to You's login UI. Users authenticate through You.
You issues per-app JWTs via auth code exchange over Erlang distribution.
```

Apps never touch You's database. All communication goes through You's API.

# App Hostnames: Why and Who Decides

Every app You serves login pages for can be given its own hostname —
`acme.example.com` instead of a `?app=acme` query parameter on You's own
address. This page explains what problem that solves, what it costs, and
which decisions are yours as the **Operator** versus the **Admin**'s to make
in the console. See [CONTEXT.md](../../CONTEXT.md) for those two roles; the
short version is that the Operator has shell access to the host and sets the
values a login depends on, and the Admin manages users and apps from inside
the product.

**Status:** live, behind two switches that are both required — see
[What this needs from you as Operator](#what-this-needs-from-you-as-operator)
below. Resolving which app a request belongs to from the `Host` header, and
the redirect rules between an app host and the canonical one (discovery and
JWKS to canonical, the OAuth machine endpoints refusing rather than
redirecting, `/console` and `/users/settings/*` staying canonical-only),
shipped together — the redirect rules are what keep a recognised app host
from also answering as an alternate issuer, so resolution was never live
without them.

## Running a single app? None of this applies

`YOU_MODE=single` provisions exactly one app, and that app already gets the
whole instance — there is no second app for a hostname, a label, or a
`?app=` parameter to disambiguate from. Skip straight past this page:
`hostname_label`, `APP_HOSTNAME_TEMPLATE`, and everything below only start
to matter once more than one app can be reached through the same instance.
See [quickstart.md](../quickstart.md) for single-app setup.

## What `?app=<slug>` cannot do

Today, an app's identity during login is carried by a query parameter:
`YouWeb.AppBranding.put_app_param/2` stashes `?app=<slug>` in the session,
and every page in the flow reads it back from there. That works, with three
problems baked in:

- **It's droppable.** Strip the query string — a link shortener, a chat
  client, a user retyping the URL by hand — and the page falls back to
  You's own unbranded chrome.
- **It's absent from anywhere a user didn't arrive through your flow.** A
  bookmark, a password manager's saved entry, a screenshot in a support
  ticket — none of them carry a query string that was only ever attached to
  one specific redirect.
- **It has to be threaded by hand through every entry point.** Anywhere a
  link to the login page is constructed outside the flow itself, someone has
  to remember to append it, and nothing enforces that they did.

A hostname carries the same fact in the address bar instead: it survives
being bookmarked, shared, or typed from memory, and it's a trust signal a
user can actually reason about — "check the domain" is advice people
follow; "check the query string" is not.

## Where the decision is made, and by whom

Two separate decisions, two separate owners:

| Decision | Who | Where |
|---|---|---|
| The hostname **pattern** — the shape app hostnames take under your domain | **Operator** | DNS zone, certificate, `PHX_HOST`, `WEBAUTHN_RP_ID` |
| An individual app's hostname **label** — which slug gets which subdomain | **Admin** | The app's settings in the console |

The pattern is yours to choose because it's infrastructure: it needs a DNS
record you control and a certificate that covers it, and it fixes what
`WEBAUTHN_RP_ID` has to be (see below). Once it's chosen, giving an app a
label is an ordinary Admin action in the console — no DNS or certificate
work is needed per app, only per pattern.

## The pattern: a dedicated domain for You

The chosen pattern is a domain dedicated to You: the canonical host at
`id.<domain>`, and each app at `<slug>.<domain>` — for example
`id.example.com` and `acme.example.com` under an `example.com` reserved for
You alone, or a domain registered solely for this purpose.

Two alternatives were considered and rejected:

- **One label under an existing shared domain** (`acme.example.com`, sharing
  `example.com` with other services). Free — covered by the wildcard
  certificate most providers issue by default — but passkeys registered on
  You's canonical host would not work on app hosts, since the WebAuthn
  relying-party ID would not be a suffix of them. It also means every other
  service on that domain has to be kept out of the app-slug namespace, which
  gets harder to manage the more the domain hosts.
- **Two labels under You's own host** (`acme.you.example.com`). Passkeys
  would work — `you.example.com` is a registrable suffix of every app host —
  but a certificate reaching two labels below the apex needs a paid
  add-on with most providers; a default wildcard covers one level only.

The dedicated domain gets both properties — passkeys work, and there's no
namespace to police — for the price of a domain registration, which is
typically cheaper than the certificate add-on the second option needs. If
your situation differs — you already pay for a certificate that reaches two
labels deep, say, or you have no interest in passkeys on app hosts — the
first two options remain valid choices; the reasoning above is what to weigh
against your own constraints, not a rule that only one answer is ever right.

## Two consequences of this pattern

### Passkeys work on app hosts

`WEBAUTHN_RP_ID` (see [deploy.md](deploy.md#environment-variables)) is set to
the domain — `example.com` in the examples above. `You.WebAuthn` gates
passkey availability on whether a request's host is that RP ID or a
subdomain of it (`available_for_host?/1`), not on exact host equality, so a
credential registered on `id.example.com` is usable on `acme.example.com`
too. That's the whole reason this pattern was chosen over the first
alternative above.

### Sessions do not follow between hosts

Signing in on `acme.example.com` does not sign you in on `id.example.com`
or on another app's host. This is deliberate, not a gap to route around, and
it's worth understanding why before you consider "fixing" it:

`YouWeb.Endpoint` sets no `:domain` on the session cookie, and there is no
environment variable to add one. A cookie scoped to the whole domain would
be *writable*, not just readable, by every host under it — any app host
could set a cookie that overwrites the one a user got from signing in
elsewhere ("cookie tossing"), which is enough to fixate a session. Widening
the cookie's domain would widen the session-derived CSRF token along with
it, so the same request forgery the token exists to stop would work across
every co-tenant host. `SameSite=Lax` doesn't help here — sibling subdomains
of the same registrable domain are already same-site to the browser, so it
does not distinguish `acme.example.com` from `id.example.com` the way it
distinguishes either from a third-party site.

The practical effect: a user of two apps on two hostnames signs in twice.
Anything that has to carry identity across a host boundary — the federated
login round trip to an external identity provider, for instance — carries
its state explicitly, signed into a URL or a short-lived record, rather than
relying on a cookie to follow.

## What not to do

**Do not widen `WEBAUTHN_RP_ID`** to make passkeys work under a pattern that
doesn't support them (the first alternative above). An RP ID that spans a
DNS zone lets *any* host in that zone request assertions for You's
credentials — not just the app hosts you intend. The fix for a host that
doesn't qualify is putting it under the pinned RP ID, never broadening the
ID to reach it.

**Changing `WEBAUTHN_RP_ID` at all strands passkeys in both directions**:
every credential registered under the old value stops matching, and if you
change it back, every credential registered under the interim value stops
matching too. Treat it as a deployment operation with a maintenance window,
the same way [deploy.md](deploy.md#environment-variables) already describes
it — not something to edit while chasing a passkey bug.

## The three ways a request names an app, and their precedence

Once a request's host is one this instance recognises at all
(`You.Hosting.own_host?/1` — the canonical host, or a host that resolves to
a configured app's label), up to three carriers can say which app the
request belongs to. `YouWeb.AuthMethods.app_for/1` is the one place that
picks between them, in this order:

1. **`callback_url`** — the callback URL of an in-flight OAuth redirect,
   matched against a registered app's own callback URL. Wins even on an
   app's own hostname: a consumer that started its flow from the canonical
   host still names its app this way.
2. **Hostname** — the request's own host, resolved against `hostname_label`
   through the configured template.
3. **`?app=<slug>`** — the query-parameter fallback described above, for an
   app with no label of its own.

None of the three is consulted on a host this instance doesn't recognise —
see the next section.

## Unrecognised hosts

A request whose host matches no app's label serves You's own unbranded
canonical pages, selects no app, and is logged (sampled, so a scripted probe
against many forged hosts can't flood the log). It does not fall back to
guessing or to the most-recently-seen app — and, as of the milestone
re-review that closed this out, it does not fall back to `?app=<slug>` or a
consumer's `callback_url` either, even though both of those still work
perfectly well on a host You *does* recognise (the canonical host, or
another app's own host). An unrecognised `Host` names no app by any route.

The reason is the same one that makes DNS the Operator's decision and not a
per-app free-for-all: if an unrecognised `Host` could select an app by any
carrier, then whoever controls that piece of DNS — not you, not the Admin
who set the label — would get to choose which app's branding and sign-in
methods a visitor sees, complete with a working passkey button under the
dedicated-domain pattern this page recommends, since `WEBAUTHN_RP_ID`
qualifies any host in its zone regardless of app resolution. Resolution has
to check against labels You actually holds, never trust the header on its
own, for every carrier that names an app — not only the hostname itself.

## What this needs from you as Operator

- A DNS zone (or subdomain of one) you're willing to dedicate to You, with a
  wildcard record pointed at this instance.
- A TLS certificate that covers that wildcard. Check the label depth against
  what your certificate actually covers — a default wildcard from most
  providers covers one level (`*.example.com` covers `acme.example.com`, not
  `acme.you.example.com`), which is exactly the tradeoff the pattern above
  was chosen to avoid needing.
- `PHX_HOST` set to the canonical host (`id.<domain>`) and, once you're
  serving more than one hostname, `WEBAUTHN_RP_ID` pinned explicitly to the
  domain rather than left to derive from `PHX_HOST` — see
  [deploy.md](deploy.md#environment-variables) for both.
- `APP_HOSTNAME_TEMPLATE` set to the pattern itself — `{label}.example.com`
  for the dedicated-domain pattern above — and a restart. Environment-only,
  same reasoning as `WEBAUTHN_RP_ID`: see
  [deploy.md](deploy.md#environment-variables).
- After configuring or changing `APP_HOSTNAME_TEMPLATE`, or after renaming
  `PHX_HOST`, run `mix you.audit_hostname_labels` (or, in a release,
  `bin/you eval 'You.Release.audit_hostname_labels()'`). It reports any
  existing app label that would now render to your own canonical host — a
  write-time guard catches this when a label is first set, but not when the
  template or `PHX_HOST` changes underneath a label already saved.

Giving an individual app its hostname label, once the pattern is live, is an
Admin action in the console and needs none of the above repeated per app —
but the "Per-app hostnames" feature switch (Features, also Admin-owned) is
what actually turns resolution on; `APP_HOSTNAME_TEMPLATE` alone does not.

# App Hostnames: Why and Who Decides

Every app You serves login pages for can be given its own hostname —
`acme.id.example.com` instead of a `?app=acme` query parameter on You's own
address. This page explains what problem that solves, what it costs, and
which decisions are yours as the **Operator** versus the **Admin**'s to make
in the console. See [CONTEXT.md](../../CONTEXT.md) for those two roles; the
short version is that the Operator has shell access to the host and sets the
values a login depends on, and the Admin manages users and apps from inside
the product.

**Status:** the hostname pattern is decided (below) and the pieces it
depends on — a pinned `WEBAUTHN_RP_ID` and a host-local session cookie — have
shipped. Resolving which app a request belongs to from the `Host` header,
and the redirect rules between an app host and the canonical one, have not
merged yet. Nothing in this page describes a feature you can turn on today;
it describes the decision an Operator needs to make before it lands, because
the pattern is far cheaper to pick before any app, passkey, or consumer has
anything pinned to a hostname.

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

## Unrecognised hosts

Once `Host`-based resolution lands, a request whose host matches no app's
label will serve You's own unbranded canonical pages, select no app, and be
logged. It will not fall back to guessing or to the most-recently-seen app.

The reason is the same one that makes DNS the Operator's decision and not a
per-app free-for-all: if an unrecognised `Host` could select an app, then
whoever controls that piece of DNS — not you, not the Admin who set the
label — would get to choose which app's branding and sign-in methods a
visitor sees. Resolution has to check against labels You actually holds,
never trust the header on its own.

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

Giving an individual app its hostname label, once the pattern is live, is an
Admin action in the console and needs none of the above repeated per app.

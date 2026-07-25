defmodule YouWeb.LandingContent do
  @moduledoc """
  Copy and data for the landing page.

  Kept out of the template so the marketing wording is editable in one place
  without wading through markup, and so the LiveView stays about behavior.
  """

  def trust_strip do
    [
      "password + TOTP 2FA",
      "magic links",
      "JWT + revocation",
      "audit log",
      "runs on your BEAM"
    ]
  end

  def console_features do
    [
      %{
        icon: "lucide-key-round",
        title: "Apps & client secrets",
        body: "Register consumer apps, issue one-time client secrets, rotate them anytime."
      },
      %{
        icon: "lucide-users",
        title: "Users & roles",
        body: "Promote admins, force a user logged out everywhere, anonymize on request."
      },
      %{
        icon: "lucide-building-2",
        title: "Organizations",
        body: "Group users into orgs with per-member roles, ready for team billing later."
      },
      %{
        icon: "lucide-scroll-text",
        title: "Live audit trail",
        body:
          "Every login, grant and admin action lands in a readable stream you can filter and forward to a webhook."
      },
      %{
        icon: "lucide-settings",
        title: "Instance settings",
        body:
          "Node name, distribution cookie, SCIM token, token lifetimes. No restarts, no config files."
      },
      %{
        icon: "lucide-ticket-check",
        title: "Sessions & tokens",
        body:
          "Short-lived JWTs with per-token revocation by JTI. Kill one session without touching the rest."
      }
    ]
  end

  def security_items do
    [
      %{
        title: "Hardened login",
        body: "Bcrypt hashing and rate limiting are on from the first request. Nothing to enable."
      },
      %{
        title: "2FA built in",
        body: "TOTP with recovery codes, wired into the login flow rather than bolted on after."
      },
      %{
        title: "Revocable sessions",
        body: "Short-lived, JTI-tracked JWTs. Pull one token without touching the rest."
      },
      %{
        title: "Audit everything",
        body: "Every login, grant and admin action lands in an audit trail you can actually read."
      }
    ]
  end

  def alternatives do
    [
      %{
        icon: "lucide-cloud",
        title: "You want zero-ops managed auth",
        body: "If running identity yourself isn't worth it, a hosted provider is a better fit.",
        pick: "Use Auth0 or Clerk",
        ours: false
      },
      %{
        icon: "lucide-server",
        title: "You're a JVM shop already",
        body: "Deep Java/Spring integration and an existing ops story around the JVM.",
        pick: "Use Keycloak",
        ours: false
      },
      %{
        icon: "lucide-shield",
        title: "You run on the BEAM and want it in-cluster",
        body:
          "Your login page never leaves your infrastructure: standard OIDC for any app, distribution-native RPC for the BEAM apps you trust.",
        pick: "Use You",
        ours: true
      }
    ]
  end

  def comparison do
    [
      %{
        label: "Who holds user credentials",
        you: "You do",
        auth0: "They do",
        keycloak: "You do"
      },
      %{label: "Protocol", you: "OIDC, JWKS, SCIM", auth0: "OIDC, SAML", keycloak: "OIDC, SAML"},
      %{
        label: "Runs on",
        you: "One container, SQLite inside",
        auth0: "Their cloud",
        keycloak: "A JVM you operate"
      },
      %{
        label: "Cost",
        you: "Free, MIT",
        auth0: "Per user per month",
        keycloak: "Free, paid in ops"
      },
      %{
        label: "Elixir integration",
        you: "OIDC plus in-cluster RPC",
        auth0: "HTTP only",
        keycloak: "HTTP only"
      },
      %{
        label: "2FA, passkeys, audit",
        you: "Built in",
        auth0: "Paid tiers",
        keycloak: "Plugins and config"
      }
    ]
  end

  def tiers do
    [
      %{
        name: "Community",
        price: "Free",
        tag: "Self-host",
        cta: "Self-host You",
        popular: true,
        points: [
          "MIT-licensed source on GitHub",
          "Prebuilt Docker image",
          "Password + 2FA + audit",
          "Unlimited consumer apps"
        ]
      }
    ]
  end

  def faqs do
    [
      %{
        q: "Is You open source?",
        a:
          "Yes. MIT-licensed, source on GitHub. You self-host it on your own cluster, so your users' data stays inside your infrastructure."
      },
      %{
        q: "How do apps connect?",
        a:
          "Two steps. Your app redirects the user to You's /users/log-in with a callback_url and scope; after login You redirects back with a single-use code. Your app then trades that code for a JWT over standard HTTP (OIDC, any language). Elixir apps you trust in your own cluster can skip HTTP entirely and call You over Erlang distribution."
      },
      %{
        q: "How is it secured?",
        a:
          "Bcrypt-hashed, rate-limited passwords; TOTP 2FA with recovery codes; single-use auth codes that expire in five minutes; JTI-tracked JWTs you can revoke individually; and a full audit trail of logins, grants and admin actions."
      },
      %{
        q: "How is it different from Auth0?",
        a:
          "Auth0 is a solid hosted IdP, but hosted means your users' credentials live on their infrastructure and you pay per user. You gives you the same OIDC standard on your own node, plus a distribution-native shortcut for trusted Elixir apps. The real question is who holds your users."
      }
    ]
  end
end

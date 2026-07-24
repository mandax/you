defmodule YouWeb.LandingContent do
  @moduledoc """
  Copy and data for the landing page.

  Kept out of the template so the marketing wording is editable in one place
  without wading through markup, and so the LiveView stays about behavior.
  """

  @connect_sample """
  # 1. your app sends the user to You to authenticate
  redirect_url =
    "https://you.example.com/users/log-in?" <>
      URI.encode_query(%{
        callback_url: "https://myapp.example.com/auth/callback",
        scope: "profile email"
      })

  redirect(conn, external: redirect_url)

  # 2. after login, You redirects back with a single-use code —
  #    your app trades it for tokens over plain HTTPS
  %{status: 200, body: tokens} =
    Req.post!("https://you.example.com/oauth/token",
      form: [code: auth_code, code_verifier: verifier])

  # 3. verify tokens.access_token locally against You's JWKS
  #    no call home per request\
  """

  def connect_sample, do: @connect_sample

  def works_with, do: ~w(Phoenix LiveView SQLite Erlang\ distribution JOSE)

  def trust_strip do
    [
      "password + TOTP 2FA",
      "magic links",
      "JWT + revocation",
      "audit log",
      "runs on your BEAM"
    ]
  end

  def tricks do
    [
      "Credential stuffing against a login endpoint with no rate limit.",
      "Session fixation across an app that never rotates its cookie.",
      "Account takeover on a login with no second factor.",
      "Replaying a stolen or leaked access token after it should be dead.",
      "Reading admin access no one is watching in an audit log."
    ]
  end

  def blocks do
    [
      %{
        title: "Hardened, rate-limited login",
        body: "Bcrypt-hashed passwords behind a login endpoint that throttles repeated failures."
      },
      %{
        title: "TOTP 2FA + recovery codes",
        body: "A second factor with backup codes for when the authenticator app is unreachable."
      },
      %{
        title: "Single-use, 5-minute auth codes",
        body: "The redirect handshake issues a code that expires fast and burns on first use."
      },
      %{
        title: "JTI revocation",
        body: "Every JWT carries a tracked ID — revoke one token without invalidating the rest."
      }
    ]
  end

  def security_items do
    [
      %{
        title: "Hardened login",
        body:
          "Bcrypt hashing and rate limiting are on from the first request — nothing to enable."
      },
      %{
        title: "2FA built in",
        body: "TOTP with recovery codes, wired into the login flow rather than bolted on after."
      },
      %{
        title: "Revocable sessions",
        body: "Short-lived, JTI-tracked JWTs — pull one token without touching the rest."
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
      %{feature: "Self-host your data", you: :yes, auth0: :no, keycloak: :yes},
      %{feature: "BEAM-native dist RPC", you: :yes, auth0: :no, keycloak: :no},
      %{feature: "No per-MAU pricing", you: :yes, auth0: :no, keycloak: :yes},
      %{feature: "Built-in 2FA + recovery", you: :yes, auth0: :yes, keycloak: :yes},
      %{feature: "Phoenix-first", you: :yes, auth0: :no, keycloak: :no},
      %{feature: "JVM-free", you: :yes, auth0: :yes, keycloak: :no}
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
          "Yes — MIT-licensed, source on GitHub. You self-host it on your own cluster, so your users' data stays inside your infrastructure."
      },
      %{
        q: "How do apps connect?",
        a:
          "Two steps. Your app redirects the user to You's /users/log-in with a callback_url and scope; after login You redirects back with a single-use code. Your app then trades that code for a JWT over standard HTTP (OIDC, any language) — or, for Elixir apps you trust in your own cluster, over Erlang distribution with no HTTP hop."
      },
      %{
        q: "How is it secured?",
        a:
          "Bcrypt-hashed, rate-limited passwords; TOTP 2FA with recovery codes; single-use auth codes that expire in five minutes; JTI-tracked JWTs you can revoke individually; and a full audit trail of logins, grants and admin actions."
      },
      %{
        q: "How is it different from Auth0?",
        a:
          "Auth0 is a solid hosted IdP — but hosted means your users' credentials live on their infrastructure and you pay per user. You gives you the same OIDC standard on your own node, plus a distribution-native shortcut for trusted Elixir apps. It's not better or worse — it's about who holds your users."
      }
    ]
  end
end

defmodule YouWeb.LandingContent do
  @moduledoc """
  Copy and data for the landing page.

  Kept out of the template so the marketing wording is editable in one place
  without wading through markup, and so the LiveView stays about behavior.
  """

  @redirect_sample """
  # your app sends the user to You to authenticate
  redirect_url =
    "https://you.internal/users/log-in?" <>
      URI.encode_query(%{
        callback_url: "https://app.internal/auth/callback",
        scope: "profile email"
      })

  redirect(conn, external: redirect_url)\
  """

  @exchange_sample """
  # your app exchanges the one-time code over Erlang
  # distribution — no HTTP hop, no shared secret to rotate
  {:ok, %{jwt: jwt, user: user}} =
    :rpc.call(:"you@10.0.0.4", You.Server, :exchange_code,
      [auth_code, "app.internal"])

  # jwt is short-lived, JTI-tracked and revocable\
  """

  def terminal_tabs do
    [
      %{id: "redirect", label: "Redirect", file: "auth_controller.ex", code: @redirect_sample},
      %{id: "exchange", label: "Exchange", file: "session_controller.ex", code: @exchange_sample}
    ]
  end

  def works_with, do: ~w(Phoenix LiveView Sockeet Erlang\ distribution JOSE)

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
        body: "Bcrypt hashing and rate limiting are on from the first request — nothing to enable."
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
        body: "Distribution-native RPC, your own node, your users' data never leaving your cluster.",
        pick: "Use You",
        ours: true
      }
    ]
  end

  @doc """
  Capability comparison. `:yes`, `:no`, or `:partial` per column.
  """
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
          "Free prebuilt Docker image",
          "Runs on your own cluster",
          "Password + 2FA + audit",
          "Unlimited consumer apps"
        ]
      },
      %{
        name: "Cloud",
        price: "Later",
        tag: "In the works",
        cta: "Contact us",
        popular: false,
        points: ["Managed IAM node", "Usage dashboard", "Email support", "SLA on request"]
      },
      %{
        name: "Enterprise",
        price: "Contact",
        tag: "Multi-tenant",
        cta: "Talk to us",
        popular: false,
        points: [
          "Multi-tenant isolation",
          "SSO federation",
          "SLA + priority",
          "Dedicated support"
        ]
      }
    ]
  end

  def faqs do
    [
      %{
        q: "Is You open source?",
        a:
          "No. You is a free, prebuilt community Docker image you self-host — the source isn't public. You run it on your own cluster, so your users' data stays inside your infrastructure."
      },
      %{
        q: "How do apps connect?",
        a:
          "Two steps. Your app redirects the user to You's /users/log-in with a callback_url and scope; after login You redirects back with a single-use code. Your app then calls exchange_code over Erlang distribution — no HTTP hop — to trade that code for a JWT."
      },
      %{
        q: "How is it secured?",
        a:
          "Bcrypt-hashed, rate-limited passwords; TOTP 2FA with recovery codes; single-use auth codes that expire in five minutes; JTI-tracked JWTs you can revoke individually; and a full audit trail of logins, grants and admin actions."
      },
      %{
        q: "How is it different from Auth0?",
        a:
          "Auth0 is hosted, per-MAU-priced, and reaches your app over HTTP. You runs on your own BEAM cluster, connects to Elixir apps over native distribution RPC, and has no seat-based pricing — you own the node and the data."
      }
    ]
  end
end

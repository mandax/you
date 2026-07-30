defmodule YouWeb.LandingContent do
  @moduledoc """
  Copy and data for the landing page.

  Kept out of the template so the marketing wording is editable in one place
  without wading through markup, and so the LiveView stays about behavior.
  """

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

  def dashboard_features do
    [
      %{
        icon: "lucide-grid-2x2",
        title: "Granted apps",
        body:
          "One card per app the user consented to, linking into it. Removing a card revokes the consent."
      },
      %{
        icon: "lucide-monitor",
        title: "Active sessions",
        body:
          "Each session with the time it signed in. The user can revoke one or sign out everywhere else."
      },
      %{
        icon: "lucide-shield-check",
        title: "Two-factor",
        body:
          "TOTP with recovery codes, or a code emailed at each password sign-in. The user turns both on and off."
      },
      %{
        icon: "lucide-key-round",
        title: "Passkeys",
        body: "Register and remove passkeys: fingerprint, face unlock or a security key."
      },
      %{
        icon: "lucide-link",
        title: "Connected accounts",
        body:
          "External providers linked to the account, each shown with its email, and unlinkable."
      },
      %{
        icon: "lucide-download",
        title: "Data export",
        body:
          "A JSON dump of the account, its consents and their scopes, at /users/settings/access_data."
      }
    ]
  end

  @doc """
  Everything that is not the console or the account area, in one list.

  Those two have their own sections above with a screencast each, so nothing
  here repeats them. `audience` drives the icon colour only: `:user` for what
  a person signing in gets, `:dev` for what an app or a script talks to.
  """
  def features do
    [
      # ── what a person signing in gets ──
      %{
        icon: "lucide-shield-check",
        audience: :user,
        title: "Hardened login",
        body: "Bcrypt hashing and rate limiting are on from the first request. Nothing to enable."
      },
      %{
        icon: "lucide-fingerprint-pattern",
        audience: :user,
        title: "Two-factor and passkeys",
        body:
          "TOTP with recovery codes, emailed codes, or a passkey instead of a password. Wired into the login flow, not bolted on after."
      },
      %{
        icon: "lucide-mail",
        audience: :user,
        title: "Magic links",
        body:
          "Email a one-time sign-in link, without taking passwords away from the users who prefer them."
      },
      # ── what an app or a script talks to ──
      %{
        icon: "lucide-badge-check",
        audience: :dev,
        title: "Standard OIDC",
        body:
          "Authorization code with PKCE, discovery, JWKS, userinfo, introspection and revocation. Any OIDC client library works."
      },
      %{
        icon: "lucide-key-round",
        audience: :dev,
        title: "Tokens verified locally",
        body:
          "Short-lived JWTs signed with Ed25519. Apps check them against the JWKS with no round trip, and single tokens are still revocable by JTI."
      },
      %{
        icon: "lucide-webhook",
        audience: :dev,
        title: "Signed webhooks",
        body:
          "Logins, token exchanges, consent changes and admin actions posted to your endpoint, signed and retried three times."
      },
      %{
        icon: "lucide-refresh-cw",
        audience: :dev,
        title: "SCIM 2.0 provisioning",
        body:
          "Create, update and deprovision users from an upstream directory or a script, at /scim/v2 with a bearer token."
      },
      %{
        icon: "lucide-square-terminal",
        audience: :dev,
        title: "Management REST API",
        body: "Automate users, apps, roles and audit reads over /api/v1 instead of clicking."
      },
      %{
        icon: "lucide-network",
        audience: :dev,
        title: "In-cluster RPC",
        body:
          "BEAM apps you trust skip HTTP entirely and call You.IAM.Server through You.SDK over Erlang distribution."
      },
      %{
        icon: "lucide-palette",
        audience: :dev,
        title: "Per-app login pages",
        body:
          "Each app's name, logo and brand color on the login its users see. The default stays plain."
      },
      %{
        icon: "lucide-scroll-text",
        audience: :dev,
        title: "Audit trail",
        body:
          "Every login, grant and admin action in one readable stream you can filter and forward."
      }
    ]
  end

  def motivation do
    %{
      eyebrow: "Why I built this",
      heading: "Free, self-hosted, good enough.",
      body:
        "I needed a free, self-hosted identity service for my projects. " <>
          "One login, one user store, no monthly bill. And I wanted it to " <>
          "run as a BEAM node I could just drop into an Erlang/OTP cluster, " <>
          "so trusted apps talk through TCP message passing instead of all " <>
          "the HTTP bureaucracy. You is that service, built for my own use " <>
          "and open for anyone who wants the same."
    }
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
        icon: "lucide-shield",
        title: "You want identity inside your own infrastructure",
        body:
          "Credentials and the login page stay on hardware you control, and any app speaks to it over standard OIDC. If those apps run on the BEAM, they can skip HTTP and talk over Erlang distribution instead.",
        pick: "Use You",
        ours: true
      }
    ]
  end

  def setup_steps do
    [
      %{
        title: "Pull and run",
        body: "Pre-built image on GitHub Container Registry. One container with SQLite inside.",
        code: """
        docker pull ghcr.io/mandax/you:latest
        docker run -d \\
          -e DATABASE_PATH=/data/you/prod.db \\
          -e SECRET_KEY_BASE=$(openssl rand -base64 48) \\
          -e PHX_HOST=you.example.com \\
          -v you-data:/data/you \\
          -p 4000:4000 \\
          ghcr.io/mandax/you:latest\
        """
      },
      %{
        title: "Bootstrap the first admin",
        body: "Creates the initial admin user; runs migrations first if needed.",
        code: """
        docker exec <container> bin/you eval \\
          'You.Release.bootstrap_admin("admin@example.com", "your-password")'\
        """
      },
      %{
        title: "Integrate an app",
        body:
          "Register the app in the console, redirect its users to <span class=\"you-badge\">You</span>, verify tokens locally against the JWKS. Any OIDC client library works.",
        code: nil
      }
    ]
  end

  def doc_links do
    repo = "https://github.com/mandax/you/blob/main/docs"

    [
      %{
        title: "Integration guide",
        body: "OIDC, JWKS verification, Erlang distribution",
        href: "#{repo}/integration.md"
      },
      %{
        title: "Deployment",
        body: "Env vars, HTTPS, mail, backups",
        href: "#{repo}/ops/deploy.md"
      },
      %{
        title: "Management REST API",
        body: "Automate users, apps, and roles",
        href: "#{repo}/api.md"
      },
      %{
        title: "Webhooks",
        body: "Signed outbound events, Stripe recipe",
        href: "#{repo}/webhooks.md"
      }
    ]
  end
end

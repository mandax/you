defmodule YouWeb.AuthMethods do
  @moduledoc """
  Which sign-in methods a request may actually use, resolved from the instance
  feature switches and the in-flight app.

  Rendering is not gating: the login page hides a disabled method's control,
  but every entry point (`UserSessionController`, `WebAuthnController`,
  `FederatedAuthController`) can be hit directly, so each has to ask here
  before doing any work. They all share this module rather than keeping their
  own copy — a copy only implements the clause its own method cares about, so
  a new instance switch silently no-ops in the ones nobody remembered.
  """
  import Plug.Conn, only: [get_session: 2]

  alias You.Admin
  alias You.Admin.App

  @doc """
  The sign-in methods available on this connection, as a list of strings.

  Resolved for its in-flight app and its request host — this is what a
  visitor can actually use right now. An instance-level switch beats a
  per-app one: if an admin turned magic links off entirely, no app can opt
  back in.
  """
  def enabled_methods(%Plug.Conn{} = conn), do: enabled_methods(app_for(conn), conn.host)

  @doc """
  The sign-in methods `app` allows on `host`.

  Passkeys are additionally gated on whether `host` qualifies for the
  configured WebAuthn RP ID (`You.WebAuthn.available_for_host?/1`) — a host
  outside it cannot complete a passkey ceremony, so the option is not offered
  there even if the app and instance both allow it. `host` must be a real
  request host: this clause has no argument that skips the check. There is
  one, `:any_host` — `previewed_methods/1` passes it, one layer down, for
  the one caller that genuinely has no host to gate against — but it is not
  reachable through this arity, so a future caller cannot open the gate by
  omission here.
  """
  def enabled_methods(app, host)
      when (is_nil(app) or is_struct(app, App)) and is_binary(host) do
    App.auth_methods()
    |> Enum.filter(&instance_offers?(&1, host))
    |> then(&App.resolved_methods(app, &1))
  end

  @doc """
  The sign-in methods `app` allows, independent of any request host.

  For the app settings preview, which describes what an app *would* offer
  rather than what today's visitor can use — there is no host to gate
  passkeys against, so, unlike `enabled_methods/2`, they are never
  host-filtered here. Named apart from `enabled_methods/2` on purpose: a
  security gate should not have a call shape a future caller can satisfy by
  omitting the one argument that turns it off.
  """
  def previewed_methods(app) do
    App.auth_methods()
    |> Enum.filter(&instance_offers?(&1, :any_host))
    |> then(&App.resolved_methods(app, &1))
  end

  @doc "Whether `method` may be used on this connection."
  def enabled?(%Plug.Conn{} = conn, method), do: method in enabled_methods(conn)

  @doc """
  The registered app this connection's page belongs to, or `nil` for a plain
  page of You's own.

  **The app-resolution precedence, stated once** — there are three ways a
  request can name an app, and this is the only place their order is
  decided. All three are gated on one prior question: is `conn.host` a host
  You recognises at all (`You.Hosting.own_host?/1` — the canonical host, or
  a host that resolves to a configured app)? An unrecognised host names no
  app, full stop, regardless of what the session or query string claim —
  see below for why that overrides one of #121's own stated acceptance
  criteria.

  On a recognised host:

  1. `callback_url` (the session's, from an in-flight OAuth handoff via
     `lookup_app_by_callback/1`). Exact-match validated at write time
     (`Admin.lookup_app_by_callback/1`), so it names the one app that
     registered that URL — the actual destination of the transaction, which
     nothing else here is allowed to override.
  2. The request host, resolved against a configured app via
     `You.Hosting.resolve/1` (#121) — off unless `feature_app_hostnames` and
     a hostname template are both configured, in which case it is the
     primary way a page identifies its app now.
  3. `?app=<slug>` / the session's `branding_app_slug` — the legacy carrier,
     kept as a fallback for a host with no label of its own.

  Naming none of the three gives You's own page, in every deployment mode.

  ## Why an unrecognised host overrides "`?app=` still works, on any host"

  #121 states both that acceptance criterion and, separately, that "an
  unrecognised host serves unbranded canonical pages, selects no app" — the
  two cannot both hold, since `?app=`/`branding_app_slug` do not themselves
  check the host at all. Without this gate, an arbitrary `Host` header plus
  `?app=<slug>` (or a `callback_url` naming a real app) serves that app's
  branded login page, complete with its enabled sign-in methods — under
  #125's dedicated-domain pattern, potentially including a passkey button
  that can actually complete a ceremony, since `You.WebAuthn.
  available_for_host?/1` and `origin_matches?/2` accept any host under the
  configured RP ID's zone regardless of app resolution. That is the
  impersonation primitive #121's "Why unknown hosts must not brand" section
  argues an unrecognised host must never grant, so that argument wins: the
  legitimate use of `?app=` — an app with no hostname label, reached on the
  canonical host — is unaffected, because canonical is always recognised;
  only a host nothing resolves to loses the ability to brand via the
  fallback carriers.
  """
  def app_for(%Plug.Conn{} = conn) do
    if You.Hosting.own_host?(conn.host) do
      callback_app(get_session(conn, :callback_url)) || host_app(conn) ||
        branding_app(get_session(conn, :branding_app_slug))
    end
  end

  defp callback_app(callback_url) do
    with url when is_binary(url) <- callback_url,
         {:ok, app} <- Admin.lookup_app_by_callback(url) do
      app
    else
      _ -> nil
    end
  end

  # `YouWeb.Plugs.ResolveAppHost` already ran this resolution once per
  # request and assigned the result (also handling the unresolved-host log)
  # — read that when present rather than asking `You.Hosting` again. Falls
  # back to asking directly for a `conn` that never went through the plug
  # (a test building a bare `%Plug.Conn{}`, say), so this stays correct
  # either way, just without the shared log.
  defp host_app(%Plug.Conn{assigns: %{host_app: app}}), do: app

  defp host_app(%Plug.Conn{host: host}) do
    case You.Hosting.resolve(host) do
      {:app, app} -> app
      _ -> nil
    end
  end

  @doc """
  The registered app named by `callback_url` and/or `branding_app_slug`
  alone — steps 1 and 3 of `app_for/1`'s precedence, with no host step in
  between.

  For a caller resolving these two values some other way than the
  connection's own session — a signed `ctx` that already crossed hosts
  explicitly, rather than a same-host session. Such a caller has no request
  host of its own to resolve step 2 against in the first place: `ctx`'s
  `branding_app_slug` was captured from the app host the flow actually
  started on, so it already carries what step 2 would have found.
  """
  def app_for(callback_url, branding_app_slug) do
    callback_app(callback_url) || branding_app(branding_app_slug)
  end

  defp branding_app(slug) when is_binary(slug) and slug != "", do: Admin.get_app_by_slug(slug)
  defp branding_app(_slug), do: nil

  defp instance_offers?("magic_link", _host), do: You.Settings.enabled?(:feature_magic_link)
  defp instance_offers?("passkey", :any_host), do: You.Settings.enabled?(:feature_passkeys)

  defp instance_offers?("passkey", host),
    do: You.Settings.enabled?(:feature_passkeys) and You.WebAuthn.available_for_host?(host)

  defp instance_offers?("social", _host), do: You.Settings.enabled?(:feature_social_login)
  defp instance_offers?(_method, _host), do: true
end

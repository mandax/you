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
  The sign-in methods available, as a list of strings.

  Given a connection, resolved for its in-flight app and its request host —
  this is what a visitor can actually use right now. Given an app directly,
  resolved with no host, which is what the app settings preview wants: what
  the app *would* offer, independent of who is looking at it or from where.
  An instance-level switch beats a per-app one either way: if an admin turned
  magic links off entirely, no app can opt back in.
  """
  def enabled_methods(%Plug.Conn{} = conn), do: enabled_methods(app_for(conn), conn.host)
  def enabled_methods(app) when is_nil(app) or is_struct(app, App),
    do: enabled_methods(app, nil)

  @doc """
  The sign-in methods `app` allows on `host` (or on any host, for `nil`).

  Passkeys are additionally gated on whether `host` qualifies for the
  configured WebAuthn RP ID (`You.WebAuthn.available_for_host?/1`) — a host
  outside it cannot complete a passkey ceremony, so the option is not offered
  there even if the app and instance both allow it.
  """
  def enabled_methods(app, host) when is_nil(app) or is_struct(app, App) do
    App.auth_methods()
    |> Enum.filter(&instance_offers?(&1, host))
    |> then(&App.resolved_methods(app, &1))
  end

  @doc """
  Whether `method` may be used, either on this connection or for an app
  resolved some other way (see `app_for/2`) — the latter for a caller that
  has an app from somewhere other than the connection's own session, such as
  a signed `ctx` that named a different app than the session does (#132).
  """
  def enabled?(%Plug.Conn{} = conn, method), do: method in enabled_methods(conn)

  def enabled?(app, method) when is_nil(app) or is_struct(app, App),
    do: method in enabled_methods(app)

  @doc """
  The registered app the in-flight OAuth handoff is for, or `nil` for a plain
  sign-in to You itself.

  An app is named either by the session's `callback_url` or by `?app=<slug>`,
  which opens that app's login page without an OAuth handoff. Naming neither
  gives You's own login page, in every deployment mode: branding stays tied to
  an app that was asked for.
  """
  def app_for(%Plug.Conn{} = conn) do
    app_for(get_session(conn, :callback_url), get_session(conn, :branding_app_slug))
  end

  @doc """
  The registered app named by `callback_url` and/or `branding_app_slug`, or
  `nil` for neither — the session-independent core `app_for/1` reads the
  connection's session into, so a caller resolving these two values some
  other way (a signed `ctx`, rather than the session) gets identical
  precedence without needing a `Plug.Conn` to read from.
  """
  def app_for(callback_url, branding_app_slug) do
    with url when is_binary(url) <- callback_url,
         {:ok, app} <- Admin.lookup_app_by_callback(url) do
      app
    else
      _ -> branding_app(branding_app_slug)
    end
  end

  defp branding_app(slug) when is_binary(slug) and slug != "", do: Admin.get_app_by_slug(slug)
  defp branding_app(_slug), do: nil

  defp instance_offers?("magic_link", _host), do: You.Settings.enabled?(:feature_magic_link)

  defp instance_offers?("passkey", host),
    do: You.Settings.enabled?(:feature_passkeys) and You.WebAuthn.available_for_host?(host)

  defp instance_offers?("social", _host), do: You.Settings.enabled?(:feature_social_login)
  defp instance_offers?(_method, _host), do: true
end

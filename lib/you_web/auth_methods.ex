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

  An instance-level switch beats a per-app one: if an admin turned magic links
  off entirely, no app can opt back in.
  """
  def enabled_methods(%Plug.Conn{} = conn), do: enabled_methods(app_for(conn))

  def enabled_methods(app) do
    App.auth_methods()
    |> Enum.filter(&instance_offers?/1)
    |> then(&App.resolved_methods(app, &1))
  end

  @doc "Whether `method` may be used on this connection."
  def enabled?(%Plug.Conn{} = conn, method), do: method in enabled_methods(conn)

  @doc """
  The registered app the in-flight OAuth handoff is for, or `nil` for a plain
  sign-in to You itself.

  In single-app mode there is no such thing as a plain sign-in to You: every
  visitor to the login page is signing in to the one app, whether they arrived
  through an OAuth handoff or typed the URL. Falling back to it is what makes
  the branding an admin sets in the console show up on the page people
  actually see — without this, `/users/log-in` renders unbranded and the
  console's settings look broken.
  """
  def app_for(%Plug.Conn{} = conn) do
    with url when is_binary(url) <- get_session(conn, :callback_url),
         {:ok, app} <- Admin.lookup_app_by_callback(url) do
      app
    else
      _ -> branding_app(conn) || You.Mode.app()
    end
  end

  defp branding_app(conn) do
    case get_session(conn, :branding_app_slug) do
      slug when is_binary(slug) and slug != "" -> Admin.get_app_by_slug(slug)
      _ -> nil
    end
  end

  defp instance_offers?("magic_link"), do: You.Settings.enabled?(:feature_magic_link)
  defp instance_offers?("passkey"), do: You.Settings.enabled?(:feature_passkeys)
  defp instance_offers?("social"), do: You.Settings.enabled?(:feature_social_login)
  defp instance_offers?(_), do: true
end

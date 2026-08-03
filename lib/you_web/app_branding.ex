defmodule YouWeb.AppBranding do
  @moduledoc """
  The app-branding assigns every page in an authentication flow renders with.

  A flow that started for an app stays that app's the whole way through —
  login, registration, password reset, second factor, consent. The app is named
  once, by the session's `callback_url` or by `?app=<slug>`, and carried in the
  session from there, so a user who clicks "create an account" from a branded
  login page does not land on You's own.

  `bare?` is what removes You's chrome: an app's page is the app's, so it gets
  the form and nothing else — no site header, no marketing panel.
  """

  import Plug.Conn, only: [put_session: 3]

  alias You.Admin.App
  alias YouWeb.AuthMethods

  @doc """
  Branding assigns for `conn`, as a keyword list to pass straight to `render/3`.
  """
  def assigns(conn) do
    app = AuthMethods.app_for(conn)

    [
      bare: app != nil,
      app_name: app && app.name,
      app_logo_url: app && app.logo_url,
      app_brand_color: app && app.brand_color,
      app_brand_color_dark: app && app.brand_color_dark,
      app_on_brand: app && app.brand_color && App.contrast_on(app.brand_color),
      app_on_brand_dark:
        app && app.brand_color && App.contrast_on(app.brand_color_dark || app.brand_color),
      app_accent_color: app && app.accent_color,
      app_accent_color_dark: app && app.accent_color_dark,
      app_headline: app && app.headline,
      app_subtitle: app && app.subtitle
    ]
  end

  @doc """
  Remembers `?app=<slug>` for the rest of the flow.

  Only sets, never clears: the slug is stashed when the flow starts and has to
  survive the pages that follow, which carry no parameter of their own. The
  login page is the one place that also clears it, so a plain `/users/log-in`
  is always You's own page.
  """
  def put_app_param(conn, %{"app" => slug}) when is_binary(slug) and slug != "" do
    put_session(conn, :branding_app_slug, slug)
  end

  def put_app_param(conn, _params), do: conn

  @doc """
  The app whose branding the signed-in account panel wears, or nil for You's
  own.

  Single-app mode makes the account area that app's user management — profile,
  sessions, passkeys, 2FA — so it carries the app's mark rather than You's.
  With several apps there is no one app to wear, and the console is never
  branded either way: it administers the instance, not an app.
  """
  def panel_app, do: You.Mode.app()

  @doc """
  Path back to the login page that keeps the flow's app.

  The login page clears the remembered slug when it is asked for without one,
  so redirecting to a bare `/users/log-in` after registering or requesting a
  reset would drop the user onto You's own page mid-flow.
  """
  def login_path(conn) do
    params =
      %{
        "app" => Plug.Conn.get_session(conn, :branding_app_slug),
        "callback_url" => Plug.Conn.get_session(conn, :callback_url)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    if params == %{}, do: "/users/log-in", else: "/users/log-in?" <> URI.encode_query(params)
  end

  @doc "The inline custom properties an app's brand colours ride in."
  def app_brand_style(nil), do: nil

  def app_brand_style(%App{} = app) do
    brand_style(
      app_brand_color: app.brand_color,
      app_on_brand: app.brand_color && App.contrast_on(app.brand_color),
      app_brand_color_dark: app.brand_color_dark,
      app_on_brand_dark:
        app.brand_color && App.contrast_on(app.brand_color_dark || app.brand_color)
    )
  end

  @doc "The inline custom properties an app's brand colours ride in."
  def brand_style(assigns) do
    if assigns[:app_brand_color] do
      "--app-brand: #{assigns[:app_brand_color]}; " <>
        "--app-on-brand: #{assigns[:app_on_brand]}; " <>
        "--app-brand-dark: #{assigns[:app_brand_color_dark] || assigns[:app_brand_color]}; " <>
        "--app-on-brand-dark: #{assigns[:app_on_brand_dark]}"
    end
  end
end

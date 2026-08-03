defmodule YouWeb.Router do
  use YouWeb, :router

  import YouWeb.UserAuth
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {YouWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :scim do
    plug :accepts, ["json"]
    plug YouWeb.SCIM.BearerAuth
  end

  pipeline :require_local_mailbox do
    plug :ensure_local_mailbox
  end

  pipeline :rate_limit_login do
    plug YouWeb.Plugs.RateLimit, key: :login
  end

  pipeline :rate_limit_registration do
    plug YouWeb.Plugs.RateLimit, key: :registration
  end

  pipeline :rate_limit_password_reset do
    plug YouWeb.Plugs.RateLimit, key: :password_reset
  end

  pipeline :rate_limit_totp do
    plug YouWeb.Plugs.RateLimit, key: :totp
  end

  pipeline :rate_limit_email_2fa do
    plug YouWeb.Plugs.RateLimit, key: :email_2fa
  end

  pipeline :rate_limit_headless_login do
    plug YouWeb.Plugs.RateLimit, key: :headless_login
  end

  pipeline :rate_limit_headless_register do
    plug YouWeb.Plugs.RateLimit, key: :headless_register
  end

  pipeline :rate_limit_oauth_token do
    plug YouWeb.Plugs.RateLimit, key: :oauth_token
  end

  scope "/", YouWeb do
    pipe_through :browser

    live_session :public, on_mount: {YouWeb.UserAuth, :default} do
      live "/", LandingLive, :index
    end
  end

  # No pipeline: crawlers get no session cookie, and neither file needs one.
  scope "/", YouWeb do
    get "/robots.txt", SEOController, :robots
    get "/sitemap.xml", SEOController, :sitemap
  end

  scope "/console", YouWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    live_session :admin, on_mount: {YouWeb.UserAuth, :default} do
      live "/", ConsoleLive, :index
      live "/apps/:slug", AppLive.Show, :show
    end

    post "/backup/export", ConsoleBackupController, :export
  end

  # Admin-only and local-transport-only: it holds magic links and 2FA codes,
  # and Swoosh runs no storage process when mail goes out over SMTP.
  scope "/console" do
    pipe_through [:browser, :require_authenticated_user, :require_admin, :require_local_mailbox]

    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end

  defp ensure_local_mailbox(conn, _opts) do
    if You.Mailer.transport() == :local do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(
        :error,
        "The mailbox only exists while mail is unconfigured; this instance delivers over SMTP."
      )
      |> Phoenix.Controller.redirect(to: "/console")
      |> halt()
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:you, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: YouWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## OIDC: public JSON endpoints for standard OpenID Connect discovery and
  ## token exchange. These allow non-BEAM consumers to integrate without
  ## Erlang distribution.

  scope "/", YouWeb do
    pipe_through :api

    get "/.well-known/openid-configuration", OIDCController, :discovery
    get "/.well-known/jwks.json", OIDCController, :jwks

    scope "/" do
      pipe_through :rate_limit_oauth_token
      post "/oauth/token", OIDCController, :create_token
    end

    get "/oauth/userinfo", OIDCController, :userinfo
    post "/oauth/introspect", OIDCController, :introspect
    post "/oauth/revoke", OIDCController, :revoke
  end

  ## Headless auth API: first-party apps authenticate users directly (no
  ## redirect / no You UI). Client-authenticated by client_id + client_secret.

  scope "/api/auth", YouWeb do
    pipe_through :api

    scope "/" do
      pipe_through :rate_limit_headless_login
      post "/login", HeadlessAuthController, :login
    end

    scope "/" do
      pipe_through :rate_limit_headless_register
      post "/register", HeadlessAuthController, :register
    end
  end

  ## Management REST API: bearer-token automation for admins (see
  ## docs/api.md). Token-authenticated, rate-limited per IP.

  pipeline :api_management do
    plug :accepts, ["json"]
    plug YouWeb.Plugs.ManagementAuth
    plug YouWeb.Plugs.RateLimit, key: :api_mgmt
  end

  scope "/api/v1", YouWeb.API.V1 do
    pipe_through :api_management

    get "/users", UsersController, :index
    post "/users", UsersController, :create
    get "/users/:id", UsersController, :show
    post "/users/:id/logout", UsersController, :logout
    delete "/users/:id", UsersController, :delete

    get "/apps", AppsController, :index
    post "/apps", AppsController, :create
    patch "/apps/:id", AppsController, :update
    delete "/apps/:id", AppsController, :delete
    put "/apps/:id/roles/:user_id", AppsController, :set_role
    delete "/apps/:id/roles/:user_id", AppsController, :remove_role

    get "/audit", AuditController, :index
  end

  ## Authentication routes

  scope "/", YouWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    get "/users/reset-password", UserResetPasswordController, :new

    scope "/" do
      pipe_through :rate_limit_registration
      post "/users/register", UserRegistrationController, :create
    end

    scope "/" do
      pipe_through :rate_limit_password_reset
      post "/users/reset-password", UserResetPasswordController, :create
    end
  end

  scope "/", YouWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/dashboard", UserDashboardController, :index
    delete "/users/dashboard/apps/:app_id", UserDashboardController, :revoke
    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
    get "/users/settings/access_data", UserSettingsController, :access_data
    delete "/users/settings/sessions", UserSettingsController, :revoke_other_sessions
    delete "/users/settings/sessions/:id", UserSettingsController, :revoke_session
    delete "/users/settings/federated/:id", UserSettingsController, :unlink_identity

    get "/users/settings/passkeys", WebAuthnController, :index
    post "/users/settings/passkeys/register/start", WebAuthnController, :start_registration
    post "/users/settings/passkeys/register/finish", WebAuthnController, :finish_registration
    delete "/users/settings/passkeys/:id", WebAuthnController, :delete_passkey

    get "/users/settings/totp", UserSettingsController, :totp_setup
    post "/users/settings/totp", UserSettingsController, :totp_enable
    delete "/users/settings/totp", UserSettingsController, :totp_disable
    post "/users/settings/email-2fa", UserSettingsController, :email_2fa_enable
    delete "/users/settings/email-2fa", UserSettingsController, :email_2fa_disable
  end

  scope "/", YouWeb do
    pipe_through [:browser]

    get "/auth/:provider", FederatedAuthController, :authorize
    get "/auth/:provider/callback", FederatedAuthController, :callback

    get "/users/log-in", UserSessionController, :new
    # Static /users/log-in/* sub-paths MUST precede the dynamic /:token
    # (magic-link) route. Phoenix matches in definition order, so otherwise
    # e.g. /users/log-in/totp is captured as token="totp".
    get "/users/log-in/totp", UserSessionController, :totp
    get "/users/log-in/totp/recovery", UserSessionController, :recovery_code
    get "/users/log-in/email-2fa", UserSessionController, :email_2fa
    post "/users/log-in/authorize", UserSessionController, :authorize_action
    get "/users/log-in/:token", UserSessionController, :confirm
    get "/users/reset-password/:token", UserResetPasswordController, :edit
    put "/users/reset-password/:token", UserResetPasswordController, :update
    delete "/users/log-out", UserSessionController, :delete

    scope "/" do
      pipe_through :rate_limit_totp
      post "/users/log-in/totp", UserSessionController, :verify_totp
      post "/users/log-in/totp/recovery", UserSessionController, :verify_recovery_code
    end

    scope "/" do
      pipe_through :rate_limit_email_2fa
      post "/users/log-in/email-2fa", UserSessionController, :verify_email_2fa
      post "/users/log-in/email-2fa/resend", UserSessionController, :resend_email_2fa
    end

    scope "/" do
      pipe_through :rate_limit_login
      post "/users/log-in", UserSessionController, :create
    end

    post "/users/log-in/passkey/start", WebAuthnController, :start_authentication
    post "/users/log-in/passkey/finish", WebAuthnController, :finish_authentication
  end

  scope "/scim/v2", YouWeb.SCIM do
    pipe_through :scim

    get "/Users", UsersController, :index
    get "/Users/:id", UsersController, :show
    post "/Users", UsersController, :create
    put "/Users/:id", UsersController, :update
    patch "/Users/:id", UsersController, :patch
    delete "/Users/:id", UsersController, :delete
  end
end

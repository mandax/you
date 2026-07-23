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

  scope "/", YouWeb do
    pipe_through :browser

    live_session :public, on_mount: {YouWeb.UserAuth, :default} do
      live "/", LandingLive, :index
    end
  end

  scope "/console", YouWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    live_session :admin, on_mount: {YouWeb.UserAuth, :default} do
      live "/", ConsoleLive, :index
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:you, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: YouWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## OIDC — public JSON endpoints for standard OpenID Connect discovery and
  ## token exchange. These allow non-BEAM consumers to integrate without
  ## Erlang distribution.

  scope "/", YouWeb do
    pipe_through :api

    get "/.well-known/openid-configuration", OIDCController, :discovery
    get "/.well-known/jwks.json", OIDCController, :jwks
    post "/oauth/token", OIDCController, :create_token
  end

  ## Authentication routes

  scope "/", YouWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
    get "/users/reset-password", UserResetPasswordController, :new
    post "/users/reset-password", UserResetPasswordController, :create
  end

  scope "/", YouWeb do
    pipe_through [:browser, :require_authenticated_user]

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
  end

  scope "/", YouWeb do
    pipe_through [:browser]

    get "/auth/:provider", FederatedAuthController, :authorize
    get "/auth/:provider/callback", FederatedAuthController, :callback

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    get "/users/reset-password/:token", UserResetPasswordController, :edit
    put "/users/reset-password/:token", UserResetPasswordController, :update
    get "/users/log-in/totp", UserSessionController, :totp
    post "/users/log-in/totp", UserSessionController, :verify_totp
    post "/users/log-in/authorize", UserSessionController, :authorize_action
    delete "/users/log-out", UserSessionController, :delete

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

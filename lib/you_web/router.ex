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

  scope "/", YouWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/admin", YouWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    live "/", AdminDashboardLive, :index
    live "/settings", AdminSettingsLive, :index
    live "/apps", AdminAppsLive, :index
    live "/users", AdminUsersLive, :index
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

  ## Authentication routes

  scope "/", YouWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", YouWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
    get "/users/settings/access_data", UserSettingsController, :access_data
  end

  scope "/", YouWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    get "/users/log-in/totp", UserSessionController, :totp
    post "/users/log-in/totp", UserSessionController, :verify_totp
    post "/users/log-in/authorize", UserSessionController, :authorize_action
    delete "/users/log-out", UserSessionController, :delete
  end
end

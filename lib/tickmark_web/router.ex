defmodule TickmarkWeb.Router do
  use TickmarkWeb, :router

  import TickmarkWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TickmarkWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TickmarkWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", TickmarkWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tickmark, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TickmarkWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TickmarkWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{TickmarkWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # Engagement screens S1-S6 (design doc). Login is enforced here; membership
      # and role are checked by the contexts on every call.
      live "/engagements", EngagementLive.Index, :index
      live "/engagements/new", EngagementLive.Index, :new
      live "/engagements/:id", EngagementLive.Show, :show
      live "/engagements/:id/imports/new", ImportLive.New, :new
      live "/engagements/:id/runs/:run_id", TestRunLive.Show, :show
      live "/engagements/:id/findings/:finding_id", FindingLive.Show, :show
      live "/engagements/:id/audit", AuditLive.Index, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", TickmarkWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{TickmarkWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end

defmodule CounterflowWeb.Router do
  use CounterflowWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CounterflowWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug CounterflowWeb.Plugs.BasicAuth
    plug CounterflowWeb.Auth, :fetch_current_user
  end

  pipeline :require_user do
    plug CounterflowWeb.Auth, :require_authenticated_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public auth endpoints
  scope "/", CounterflowWeb do
    pipe_through :browser

    live "/login", LoginLive
    get "/auth/finish", AuthController, :finish
    get "/auth/logout", AuthController, :logout
  end

  scope "/", CounterflowWeb do
    pipe_through [:browser, :require_user]

    live_session :authenticated, on_mount: {CounterflowWeb.Auth, :ensure_authenticated} do
      live "/", PanelLive
      live "/overview", OverviewLive
      live "/watchlist", WatchlistLive
      live "/signals", SignalsLive
      live "/symbol/:symbol", SymbolLive
      live "/settings", SettingsLive
      live "/settings/:symbol", SettingsLive
      live "/paper", PaperLive
      live "/debug", DebugLive
      live "/backtest", BacktestLive
      live "/audit", AuditLive
    end
  end

  if Application.compile_env(:counterflow, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CounterflowWeb.Telemetry
    end
  end
end

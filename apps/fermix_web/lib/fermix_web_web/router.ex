defmodule FermixWebWeb.Router do
  use FermixWebWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FermixWebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FermixWebWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/setup", SetupLive
  end

  scope "/", FermixWebWeb do
    pipe_through :api

    get "/health", HealthController, :ready
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
    post "/webhook/telegram", WebhookController, :telegram
    get "/webhook/whatsapp", WebhookController, :whatsapp_verify
    post "/webhook/whatsapp", WebhookController, :whatsapp
    post "/webhook/slack", WebhookController, :slack
  end
end

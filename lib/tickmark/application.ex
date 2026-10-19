defmodule Tickmark.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TickmarkWeb.Telemetry,
      Tickmark.Repo,
      {Oban, Application.fetch_env!(:tickmark, Oban)},
      {DNSCluster, query: Application.get_env(:tickmark, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tickmark.PubSub},
      TickmarkWeb.Presence,
      # Start to serve requests, typically the last entry
      TickmarkWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tickmark.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TickmarkWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

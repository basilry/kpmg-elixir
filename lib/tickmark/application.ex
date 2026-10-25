defmodule Tickmark.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        TickmarkWeb.Telemetry,
        Tickmark.Repo,
        {Oban, Application.fetch_env!(:tickmark, Oban)},
        {DNSCluster, query: Application.get_env(:tickmark, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Tickmark.PubSub},
        TickmarkWeb.Presence,
        # Start to serve requests, typically the last entry
        TickmarkWeb.Endpoint
      ] ++ demo_seed_children()

    # Telemetry handlers are global, not tied to a process, so this can run
    # before Oban starts. It records final failures of jobs that raised.
    :ok = Tickmark.Jobs.FailureHandler.attach()

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

  # Runs after Oban and the endpoint are up, since the seed waits for Oban
  # jobs. A Task child is :temporary, so a failed seed is logged once and not
  # restarted in a loop.
  defp demo_seed_children do
    if Application.get_env(:tickmark, :seed_demo_on_boot, false) do
      [Supervisor.child_spec({Task, &Tickmark.Demo.seed_on_boot/0}, id: :demo_seed)]
    else
      []
    end
  end
end

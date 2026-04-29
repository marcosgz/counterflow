defmodule Counterflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CounterflowWeb.Telemetry,
      Counterflow.Repo,
      {DNSCluster, query: Application.get_env(:counterflow, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Counterflow.PubSub},
      {Finch, name: Counterflow.Finch},
      Counterflow.Risk.KillSwitch,
      Counterflow.Strategy.Cooldown,
      Counterflow.Strategy.Diagnostics,
      Counterflow.Ingest.Supervisor,
      {Counterflow.Strategy.Pipeline,
       enabled?: Application.get_env(:counterflow, :strategy_pipeline_enabled?, true),
       intervals: Application.get_env(:counterflow, :strategy_intervals, ["1m", "5m"])},
      {Counterflow.Bridge.SignalToPaper, enabled?: Application.get_env(:counterflow, :paper_bridge_enabled?, true)},
      {Counterflow.Broker.Paper.Matcher, enabled?: Application.get_env(:counterflow, :paper_matcher_enabled?, true)},
      {Counterflow.Watchlist.Promoter, enabled?: Application.get_env(:counterflow, :promoter_enabled?, true)},
      {Counterflow.Strategy.OutcomeEvaluator, enabled?: Application.get_env(:counterflow, :outcome_evaluator_enabled?, true)},
      {Counterflow.Backtest.AutoTuner, enabled?: Application.get_env(:counterflow, :auto_tuner_enabled?, true)},
      {Counterflow.Reports.Scheduler, enabled?: Application.get_env(:counterflow, :digest_scheduler_enabled?, true)},
      CounterflowWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Counterflow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CounterflowWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

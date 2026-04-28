defmodule Counterflow.Ingest.Supervisor do
  @moduledoc """
  Top-level ingest supervision tree.

  - Registry: per-symbol-worker lookup
  - Watchlist.DynamicSupervisor: per-symbol kline workers + ws clients
  - Watchlist.Manager: drives the dynamic supervisor based on the watchlist table
  - WS.Liquidations: single ws connection to !forceOrder@arr (universe)
  - Pollers (OI, LSR, Funding): periodic REST fetches
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    seed = Application.get_env(:counterflow, :watchlist_seed, ["BTCUSDT", "ETHUSDT"])
    intervals = Application.get_env(:counterflow, :watchlist_intervals, ["1m", "5m"])
    pollers_enabled? = Application.get_env(:counterflow, :pollers_enabled?, true)
    liquidations_enabled? = Application.get_env(:counterflow, :liquidations_enabled?, true)

    children =
      [
        Counterflow.Ingest.Registry,
        {DynamicSupervisor,
         name: Counterflow.Watchlist.DynamicSupervisor, strategy: :one_for_one},
        {Counterflow.Watchlist.Manager, seed: seed, intervals: intervals}
      ]
      |> maybe_add(liquidations_enabled?, Counterflow.Binance.WS.Liquidations)
      |> maybe_add(pollers_enabled?, Counterflow.Ingest.Poller.OpenInterest)
      |> maybe_add(pollers_enabled?, Counterflow.Ingest.Poller.LSR)
      |> maybe_add(pollers_enabled?, Counterflow.Ingest.Poller.Funding)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_add(children, true, mod), do: children ++ [mod]
  defp maybe_add(children, _false, _mod), do: children
end

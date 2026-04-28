defmodule Counterflow.Ingest.Supervisor do
  @moduledoc """
  Top-level supervisor for ingest. Phase 1: a single hard-coded
  symbol/interval pair, started at boot for the smoke test. Phase 2
  replaces this with dynamic per-symbol supervision.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    pairs = Application.get_env(:counterflow, :phase1_pairs, [{"BTCUSDT", "1m"}])

    workers =
      Enum.flat_map(pairs, fn {sym, int} ->
        [
          {Counterflow.Ingest.SymbolWorker, symbol: sym, interval: int},
          {Counterflow.Binance.WS.Kline, symbol: sym, interval: int}
        ]
      end)

    children = [Counterflow.Ingest.Registry | workers]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

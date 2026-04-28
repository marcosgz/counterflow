defmodule Counterflow.Strategy.Diagnostics do
  @moduledoc """
  ETS-backed snapshot of the latest strategy evaluation per (symbol, interval).

  The Pipeline writes a row each time it evaluates a closed candle; the
  /debug LiveView reads from here to show why a symbol is or isn't firing
  signals. No coupling to GenServer state — every evaluation is independent.

  Stored shape: `{ {symbol, interval}, %{
    evaluated_at, candle_time, candle_close, score, threshold, components,
    side_chosen, status, status_detail
  } }`

  Statuses (atoms):
    * :emitted          — signal passed all gates and was dispatched
    * :neutral          — directional cues didn't agree
    * :below_threshold  — directional bias OK, score below threshold
    * :trend_filter     — score OK but trend filter rejected the side
    * :side_disabled    — config has the side off for this symbol
    * :cooldown         — duplicate within cooldown window
    * :precheck_disabled — symbol's config has enabled = false
    * :precheck_tf_low  — TF level < min_tf_level
    * :error            — an exception fired during evaluation
  """

  use GenServer

  @table :counterflow_strategy_diag
  @max_rows 200

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Record a single evaluation result."
  def record(symbol, interval, payload) when is_map(payload) do
    row =
      payload
      |> Map.put_new(:evaluated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    :ets.insert(@table, {{symbol, interval}, row})
    Phoenix.PubSub.broadcast(Counterflow.PubSub, "diagnostics:update", {:diag, symbol, interval, row})
    :ok
  end

  @doc "Latest evaluation for one (symbol, interval)."
  def lookup(symbol, interval) do
    case :ets.lookup(@table, {symbol, interval}) do
      [{_, row}] -> row
      [] -> nil
    end
  end

  @doc "Full snapshot, sorted by most recent eval first; capped at @max_rows."
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{sym, int}, row} -> Map.merge(row, %{symbol: sym, interval: int}) end)
    |> Enum.sort_by(& &1.evaluated_at, {:desc, DateTime})
    |> Enum.take(@max_rows)
  end

  def reset, do: :ets.delete_all_objects(@table)
end

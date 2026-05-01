defmodule Counterflow.Watchlist.Manager do
  @moduledoc """
  Coordinates the watchlist: holds a cached snapshot of symbols, drives the
  dynamic supervisor that owns per-symbol ingestion, and runs a periodic
  rebalance pass that auto-promotes/demotes by activity.

  Phase 2 ships a *manual* watchlist (seeded at boot from config or DB);
  the auto-promotion algorithm lives behind `rebalance/0` but is not yet
  wired to a timer — call manually via Mix or unit tests until Phase 3
  indicators land. This keeps the surface area small and observable.
  """

  use GenServer
  require Logger

  alias Counterflow.{Repo, Market.WatchlistEntry}
  alias Counterflow.Ingest.SymbolWorker
  alias Counterflow.Binance.WS.Kline

  import Ecto.Query

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def symbols, do: GenServer.call(__MODULE__, :symbols)
  def add(symbol), do: GenServer.call(__MODULE__, {:add, symbol}, 5_000)
  def drop(symbol), do: GenServer.call(__MODULE__, {:drop, symbol}, 5_000)

  @impl true
  def init(opts) do
    seed = Keyword.get(opts, :seed, [])
    intervals = Keyword.get(opts, :intervals, ["1m", "5m"])
    Enum.each(seed, fn s -> ensure_entry(s, "manual") end)

    state = %{
      symbols: load_symbols(),
      intervals: intervals
    }

    Enum.each(state.symbols, &start_symbol(&1, state.intervals))

    {:ok, state}
  end

  @impl true
  def handle_call(:symbols, _from, state), do: {:reply, state.symbols, state}

  @impl true
  def handle_call({:add, symbol}, _from, state) do
    if symbol in state.symbols do
      {:reply, :ok, state}
    else
      ensure_entry(symbol, "manual")
      start_symbol(symbol, state.intervals)
      refresh_pipeline()
      {:reply, :ok, %{state | symbols: [symbol | state.symbols]}}
    end
  end

  def handle_call({:drop, symbol}, _from, state) do
    stop_symbol(symbol, state.intervals)

    if uid = Counterflow.Accounts.owner_id() do
      Repo.delete_all(from w in WatchlistEntry, where: w.user_id == ^uid and w.symbol == ^symbol)
    end

    refresh_pipeline()
    {:reply, :ok, %{state | symbols: List.delete(state.symbols, symbol)}}
  end

  defp refresh_pipeline do
    if pid = Process.whereis(Counterflow.Strategy.Pipeline), do: send(pid, :subscribe)
  end

  # ── helpers ─────────────────────────────────────────────────

  defp load_symbols do
    case Counterflow.Accounts.owner_id() do
      nil ->
        []

      uid ->
        Repo.all(
          from w in WatchlistEntry,
            where: w.user_id == ^uid,
            order_by: [desc: w.pinned, asc: w.symbol],
            select: w.symbol
        )
    end
  end

  defp ensure_entry(symbol, by) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Counterflow.Accounts.owner_id() do
      nil ->
        :ok

      uid ->
        Repo.insert!(
          %WatchlistEntry{
            user_id: uid,
            symbol: symbol,
            added_at: now,
            pinned: by == "manual",
            promoted_by: by,
            last_active_at: now
          },
          on_conflict: :nothing,
          conflict_target: [:user_id, :symbol]
        )
    end
  end

  defp start_symbol(symbol, intervals) do
    # Async backfill so the symbol has 7d of history immediately, instead
    # of waiting for ws candles to accumulate.
    if Application.get_env(:counterflow, :backfill_on_promote?, true) do
      Counterflow.Ingest.Backfill.start_async(symbol, intervals: intervals, days: 7)
    end

    Enum.each(intervals, fn interval ->
      worker_spec = {SymbolWorker, symbol: symbol, interval: interval}
      ws_spec = {Kline, symbol: symbol, interval: interval}

      with :ok <- start_child(worker_spec),
           :ok <- start_child(ws_spec) do
        :ok
      end
    end)
  end

  defp stop_symbol(symbol, intervals) do
    Enum.each(intervals, fn interval ->
      ws_name = :"binance_ws_kline_#{symbol}_#{interval}"
      stop_pid(Process.whereis(ws_name))

      case Registry.lookup(Counterflow.Ingest.Registry, {:symbol, symbol, interval}) do
        [{pid, _}] -> stop_pid(pid)
        _ -> :ok
      end
    end)
  end

  defp start_child(spec) do
    case DynamicSupervisor.start_child(Counterflow.Watchlist.DynamicSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, err} ->
        Logger.warning("watchlist start_child failed: #{inspect(err)}")
        :error
    end
  end

  defp stop_pid(nil), do: :ok

  defp stop_pid(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(Counterflow.Watchlist.DynamicSupervisor, pid)
  end
end

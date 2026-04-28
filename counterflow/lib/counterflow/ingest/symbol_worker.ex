defmodule Counterflow.Ingest.SymbolWorker do
  @moduledoc """
  Holds in-memory state for a (symbol, interval) ingest pair.

  Receives parsed kline events, persists closed candles, broadcasts
  ticks for live UI consumption, and maintains the latest in-flight
  candle so LiveView mounts can hydrate without a DB query.
  """

  use GenServer
  require Logger

  alias Counterflow.{Repo, Market.Candle}
  alias Counterflow.Ingest.Registry, as: IRegistry
  alias Phoenix.PubSub

  @history_size 720

  # ── public API ──────────────────────────────────────────────

  def start_link(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    interval = Keyword.fetch!(opts, :interval)
    GenServer.start_link(__MODULE__, opts, name: IRegistry.via({:symbol, symbol, interval}))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :symbol), Keyword.fetch!(opts, :interval)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Push a parsed kline event to the worker."
  def push(symbol, interval, event) do
    case Registry.lookup(IRegistry, {:symbol, symbol, interval}) do
      [{pid, _}] -> GenServer.cast(pid, {:kline, event})
      [] -> :no_worker
    end
  end

  @doc "Snapshot the current in-memory candle history for a symbol/interval."
  def snapshot(symbol, interval) do
    case Registry.lookup(IRegistry, {:symbol, symbol, interval}) do
      [{pid, _}] -> GenServer.call(pid, :snapshot)
      [] -> {:error, :not_started}
    end
  end

  # ── server callbacks ────────────────────────────────────────

  @impl true
  def init(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    interval = Keyword.fetch!(opts, :interval)

    state = %{
      symbol: symbol,
      interval: interval,
      candles: load_recent(symbol, interval),
      open: nil
    }

    {:ok, state, {:continue, :backfill}}
  end

  @impl true
  def handle_continue(:backfill, %{candles: cs} = state) when length(cs) > 0,
    do: {:noreply, state}

  def handle_continue(:backfill, %{symbol: s, interval: i} = state) do
    case Counterflow.Binance.Rest.klines(s, i, limit: @history_size) do
      {:ok, rows} ->
        candles = Enum.map(rows, &kline_row_to_candle(&1, s, i, true))
        _ = persist_batch(candles)
        {:noreply, %{state | candles: candles}}

      {:error, err} ->
        Logger.warning("backfill failed for #{s}/#{i}: #{Exception.message(err)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:kline, event}, %{symbol: s, interval: i} = state) do
    candle = parse_event(event, s, i)

    {candles, broadcast_kind} =
      if candle.closed do
        _ = persist_batch([candle])
        list = (state.candles ++ [candle]) |> Enum.take(-@history_size)
        {list, :closed}
      else
        {state.candles, :tick}
      end

    PubSub.broadcast(Counterflow.PubSub, topic(s, i), {:candle, broadcast_kind, candle})

    if broadcast_kind == :closed do
      PubSub.broadcast(Counterflow.PubSub, "candles:closed:firehose", {:closed_candle, candle})
    end

    :telemetry.execute([:counterflow, :candle, broadcast_kind], %{count: 1}, %{
      symbol: s,
      interval: i
    })

    {:noreply, %{state | candles: candles, open: if(candle.closed, do: nil, else: candle)}}
  end

  @impl true
  def handle_call(:snapshot, _from, %{candles: cs, open: o} = state) do
    {:reply, %{closed: cs, open: o}, state}
  end

  # ── helpers ─────────────────────────────────────────────────

  def topic(symbol, interval), do: "candles:#{symbol}:#{interval}"

  defp load_recent(symbol, interval) do
    import Ecto.Query

    Repo.all(
      from c in Candle,
        where: c.symbol == ^symbol and c.interval == ^interval and c.closed == true,
        order_by: [asc: c.time],
        limit: @history_size
    )
  end

  defp persist_batch([]), do: :ok

  defp persist_batch(candles) do
    rows =
      Enum.map(candles, fn c ->
        %{
          symbol: c.symbol,
          interval: c.interval,
          time: c.time,
          open: c.open,
          high: c.high,
          low: c.low,
          close: c.close,
          volume: c.volume,
          quote_volume: c.quote_volume,
          trades: c.trades,
          taker_buy_base: c.taker_buy_base,
          taker_buy_quote: c.taker_buy_quote,
          closed: c.closed
        }
      end)

    Repo.insert_all(Candle, rows,
      on_conflict: {:replace_all_except, [:symbol, :interval, :time]},
      conflict_target: [:symbol, :interval, :time]
    )

    :ok
  end

  # parse a raw kline ws frame: %{"e" => "kline", "k" => %{...}}
  defp parse_event(%{"k" => k}, symbol, interval) do
    %Candle{
      symbol: symbol,
      interval: interval,
      time: ms_to_dt(Map.fetch!(k, "t")),
      open: dec(k["o"]),
      high: dec(k["h"]),
      low: dec(k["l"]),
      close: dec(k["c"]),
      volume: dec(k["v"]),
      quote_volume: dec(k["q"]),
      trades: k["n"] || 0,
      taker_buy_base: dec(k["V"]),
      taker_buy_quote: dec(k["Q"]),
      closed: !!k["x"]
    }
  end

  # parse a REST /klines row (positional list)
  defp kline_row_to_candle(
         [t, o, h, l, c, v, _ct, qv, n, tbb, tbq, _ignore],
         symbol,
         interval,
         closed?
       ) do
    %Candle{
      symbol: symbol,
      interval: interval,
      time: ms_to_dt(t),
      open: dec(o),
      high: dec(h),
      low: dec(l),
      close: dec(c),
      volume: dec(v),
      quote_volume: dec(qv),
      trades: n,
      taker_buy_base: dec(tbb),
      taker_buy_quote: dec(tbq),
      closed: closed?
    }
  end

  defp dec(nil), do: nil
  defp dec(n) when is_binary(n), do: Decimal.new(n)
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)

  # Binance times are unix-ms; Ecto :utc_datetime_usec requires microsecond precision.
  defp ms_to_dt(ms) when is_integer(ms) do
    DateTime.from_unix!(ms * 1000, :microsecond)
  end
end

defmodule Counterflow.Strategy.Pipeline do
  @moduledoc """
  Auto-invokes the strategy on every closed candle for the watchlist.

  The pipeline subscribes to `candles:<symbol>:<interval>` PubSub topics for
  each enabled (symbol, interval) pair. When a closed candle arrives it
  builds a `Counterflow.Strategy.Input` from the most recent hypertable rows
  and evaluates the configured strategy. Successful signals pass through the
  cooldown gate and the dispatcher (DB insert + PubSub fan-out + alert sinks).

  The actual work runs inside a Task per event so a slow DB query never
  blocks subsequent candle events.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Counterflow.{Repo, Watchlist}
  alias Counterflow.Market.{Candle, OpenInterest, FundingRate, LongShortRatio, Liquidation}
  alias Counterflow.Strategy.Counterflow, as: CounterflowStrategy
  alias Counterflow.Strategy.{Cooldown, Dispatcher, Input}
  alias Counterflow.Indicators.{BucketedForce, EMA, OIDelta, FundingZ, LiquidationPulse, LSRSignal}
  alias Phoenix.PubSub

  @history 100

  # ── public API ──────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @doc "Re-subscribe after the watchlist changes (called by Watchlist.Manager)."
  def refresh_subscriptions, do: GenServer.cast(__MODULE__, :refresh_subscriptions)

  # ── server callbacks ────────────────────────────────────────

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? do
      state = %{
        intervals: Keyword.get(opts, :intervals, ["5m"]),
        strategy_opts: Keyword.get(opts, :strategy_opts, []),
        subscribed: MapSet.new()
      }

      send(self(), :subscribe)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:subscribe, state), do: {:noreply, do_subscribe(state)}

  def handle_info({:candle, :closed, %Candle{} = candle}, state) do
    Task.start(fn -> evaluate_and_dispatch(candle, state.strategy_opts) end)
    {:noreply, state}
  end

  def handle_info({:candle, :tick, _}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast(:refresh_subscriptions, state), do: {:noreply, do_subscribe(state)}

  # ── work ────────────────────────────────────────────────────

  defp do_subscribe(state) do
    desired =
      for symbol <- Watchlist.symbols(),
          interval <- state.intervals,
          into: MapSet.new(),
          do: {symbol, interval}

    to_add = MapSet.difference(desired, state.subscribed)
    to_drop = MapSet.difference(state.subscribed, desired)

    Enum.each(to_add, fn {sym, int} ->
      PubSub.subscribe(Counterflow.PubSub, "candles:#{sym}:#{int}")
    end)

    Enum.each(to_drop, fn {sym, int} ->
      PubSub.unsubscribe(Counterflow.PubSub, "candles:#{sym}:#{int}")
    end)

    if MapSet.size(to_add) + MapSet.size(to_drop) > 0 do
      Logger.info(
        "Strategy.Pipeline subscribed: +#{MapSet.size(to_add)} -#{MapSet.size(to_drop)} (total #{MapSet.size(desired)})"
      )
    end

    %{state | subscribed: desired}
  end

  defp evaluate_and_dispatch(%Candle{symbol: sym, interval: int} = candle, strategy_opts) do
    input = build_input(sym, int, candle)

    case CounterflowStrategy.evaluate(input, strategy_opts) do
      :no_signal ->
        :ok

      {:signal, sig} ->
        case Cooldown.maybe_emit(sig.symbol, sig.side, sig.interval) do
          :ok ->
            Dispatcher.dispatch(sig)
            :telemetry.execute([:counterflow, :strategy, :signal, :emitted], %{count: 1}, %{symbol: sig.symbol, side: sig.side})

          :cooldown ->
            :telemetry.execute([:counterflow, :strategy, :signal, :cooldown], %{count: 1}, %{symbol: sig.symbol, side: sig.side})
        end
    end
  rescue
    err ->
      Logger.warning("strategy pipeline error for #{sym}/#{int}: #{Exception.message(err)}")
      :telemetry.execute([:counterflow, :strategy, :error], %{count: 1}, %{symbol: sym, kind: err.__struct__})
  end

  defp build_input(symbol, interval, %Candle{time: candle_time} = candle) do
    history = load_history(symbol, interval, candle_time)
    closes = Enum.map(history, & &1.close)
    oi = load_oi(symbol, candle_time)
    lsr = load_lsr(symbol, candle_time)
    funding = load_funding(symbol, candle_time)
    liqs = load_liquidations(symbol, candle_time)

    %Input{
      symbol: symbol,
      interval: interval,
      candle: candle,
      candles: history,
      tf: BucketedForce.calculate(history, &BucketedForce.trades_extractor/1),
      pf: BucketedForce.calculate(history, &BucketedForce.body_extractor/1),
      vf: BucketedForce.calculate(history, &BucketedForce.volume_extractor/1),
      ema_fast: EMA.last(closes, 7),
      ema_slow: EMA.last(closes, 25),
      ema_very_slow: EMA.last(closes, 99),
      oi_delta: OIDelta.calculate(oi, history),
      funding_z: FundingZ.calculate(funding),
      liq_pulse: LiquidationPulse.calculate(liqs, now: candle_time),
      lsr_signal: LSRSignal.calculate(lsr),
      now: candle_time
    }
  end

  defp load_history(symbol, interval, until) do
    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^symbol and c.interval == ^interval and c.closed == true and
            c.time <= ^until,
        order_by: [desc: c.time],
        limit: @history
    )
    |> Enum.reverse()
  end

  defp load_oi(symbol, until) do
    Repo.all(
      from o in OpenInterest,
        where: o.symbol == ^symbol and o.time <= ^until,
        order_by: [desc: o.time],
        limit: 12
    )
    |> Enum.reverse()
  end

  defp load_lsr(symbol, until) do
    Repo.all(
      from l in LongShortRatio,
        where: l.symbol == ^symbol and l.source == "global_account" and l.time <= ^until,
        order_by: [desc: l.time],
        limit: 30
    )
    |> Enum.reverse()
  end

  defp load_funding(symbol, until) do
    Repo.all(
      from f in FundingRate,
        where: f.symbol == ^symbol and f.time <= ^until,
        order_by: [desc: f.time],
        limit: 30
    )
    |> Enum.reverse()
  end

  defp load_liquidations(symbol, until) do
    cutoff = DateTime.add(until, -60 * 60, :second)

    Repo.all(
      from l in Liquidation,
        where: l.symbol == ^symbol and l.time >= ^cutoff and l.time <= ^until,
        order_by: [asc: l.time]
    )
  end
end

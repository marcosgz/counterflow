defmodule Counterflow.Backtest.Replayer do
  @moduledoc """
  Replays historical candles + indicator inputs through the strategy pipeline,
  emitting deterministic signals.

  Single-symbol single-interval driver. Walk-forward orchestration and
  parameter sweep live in companion modules.
  """

  import Ecto.Query

  alias Counterflow.{Repo, Clock}
  alias Counterflow.Market.{Candle, OpenInterest, FundingRate, LongShortRatio, Liquidation}
  alias Counterflow.Strategy
  alias Counterflow.Strategy.Input
  alias Counterflow.Indicators.{BucketedForce, EMA, OIDelta, FundingZ, LiquidationPulse, LSRSignal}

  @history 100

  @type opts :: keyword()
  @type report :: %{
          signals: list(),
          candles_processed: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @spec run(opts()) :: report()
  def run(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    interval = Keyword.fetch!(opts, :interval)
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    strategy_mod = Keyword.get(opts, :strategy, Counterflow.Strategy.Counterflow)
    strategy_opts = Keyword.get(opts, :strategy_opts, [])

    started = System.monotonic_time(:millisecond)
    candles = load_candles(symbol, interval, from, to)
    oi_series = load_oi(symbol, from, to)
    lsr_series = load_lsr(symbol, from, to)
    funding_series = load_funding(symbol, from, to)
    liq_series = load_liquidations(symbol, from, to)

    signals =
      candles
      |> Enum.with_index()
      |> Enum.reduce([], fn {candle, idx}, acc ->
        Clock.set_replay_now(candle.time)

        history = candles |> Enum.slice(max(0, idx - @history)..idx)
        oi_window = filter_until(oi_series, candle.time) |> Enum.take(-12)
        lsr_window = filter_until(lsr_series, candle.time) |> Enum.take(-30)
        funding_window = filter_until(funding_series, candle.time) |> Enum.take(-30)
        liq_window = filter_until(liq_series, candle.time)

        input = build_input(symbol, interval, candle, history, oi_window, lsr_window, funding_window, liq_window)

        case strategy_mod.evaluate(input, strategy_opts) do
          {:signal, sig} -> [sig | acc]
          :no_signal -> acc
        end
      end)
      |> Enum.reverse()

    Clock.clear_replay()

    %{
      signals: signals,
      candles_processed: length(candles),
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp build_input(symbol, interval, candle, history, oi, lsr, funding, liqs) do
    closes = Enum.map(history, & &1.close)

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
      liq_pulse: LiquidationPulse.calculate(liqs, now: candle.time),
      lsr_signal: LSRSignal.calculate(lsr),
      now: candle.time
    }
  end

  defp load_candles(symbol, interval, from, to) do
    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^symbol and c.interval == ^interval and c.closed == true and
            c.time >= ^from and c.time < ^to,
        order_by: [asc: c.time]
    )
  end

  defp load_oi(symbol, from, to) do
    Repo.all(from o in OpenInterest, where: o.symbol == ^symbol and o.time >= ^from and o.time < ^to, order_by: [asc: o.time])
  end

  defp load_lsr(symbol, from, to) do
    Repo.all(
      from l in LongShortRatio,
        where: l.symbol == ^symbol and l.source == "global_account" and l.time >= ^from and l.time < ^to,
        order_by: [asc: l.time]
    )
  end

  defp load_funding(symbol, from, to) do
    Repo.all(from f in FundingRate, where: f.symbol == ^symbol and f.time >= ^from and f.time < ^to, order_by: [asc: f.time])
  end

  defp load_liquidations(symbol, from, to) do
    Repo.all(from l in Liquidation, where: l.symbol == ^symbol and l.time >= ^from and l.time < ^to, order_by: [asc: l.time])
  end

  defp filter_until(series, %DateTime{} = ts) do
    Enum.take_while(series, fn item -> DateTime.compare(item.time, ts) != :gt end)
  end
end

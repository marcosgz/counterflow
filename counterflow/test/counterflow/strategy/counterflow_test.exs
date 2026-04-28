defmodule Counterflow.Strategy.CounterflowStrategyTest do
  use ExUnit.Case, async: true

  alias Counterflow.Strategy.Counterflow, as: Strategy
  alias Counterflow.Strategy.Input
  alias Counterflow.Market.Candle

  defp candle(close, open, high, low) do
    %Candle{
      symbol: "BTCUSDT",
      interval: "5m",
      time: ~U[2026-04-28 12:00:00.000000Z],
      open: Decimal.new("#{open}"),
      high: Decimal.new("#{high || max(close, open)}"),
      low: Decimal.new("#{low || min(close, open)}"),
      close: Decimal.new("#{close}"),
      volume: Decimal.new("0"),
      trades: 0
    }
  end

  defp baseline_input(opts) do
    last = candle(opts[:close] || 100, opts[:open] || 99, opts[:high], opts[:low])

    %Input{
      symbol: "BTCUSDT",
      interval: "5m",
      candle: last,
      candles: [candle(99, 98, 99.5, 97), candle(99.5, 99, 100, 98), last],
      tf: opts[:tf] || %{level: 0, avg: 0.0, latest: 0.0},
      pf: %{level: 0, avg: 0.0, latest: 0.0},
      vf: %{level: 0, avg: 0.0, latest: 0.0},
      ema_fast: opts[:ema_fast] || 99.0,
      ema_slow: opts[:ema_slow] || 98.5,
      oi_delta: opts[:oi] || %{signal: :neutral, oi_change_pct: 0.0, price_change_pct: 0.0},
      funding_z: opts[:funding] || %{z: 0.0, latest: 0.0, mean: 0.0, stddev: 0.0},
      liq_pulse: opts[:liq] || %{percentile: 0.0, recent_total: 0.0, direction: :none},
      lsr_signal:
        opts[:lsr] || %{raw: 1.0, rsi: 50.0, ema_fast: 1.0, ema_slow: 1.0, extreme: :neutral},
      now: ~U[2026-04-28 12:00:00.000000Z]
    }
  end

  test "no signal when nothing aligns" do
    assert Strategy.evaluate(baseline_input([])) == :no_signal
  end

  test "fires SHORT when funding extreme + longs_trapped + TF bearish spike" do
    input =
      baseline_input(
        close: 99,
        open: 100,
        high: 101,
        low: 99,
        ema_fast: 99.5,
        ema_slow: 100.0,
        tf: %{level: 6, avg: 1.0, latest: 6.0},
        oi: %{signal: :longs_trapped, oi_change_pct: 0.05, price_change_pct: -0.03},
        funding: %{z: 2.5, latest: 0.0005, mean: 0.0001, stddev: 0.00016},
        liq: %{percentile: 0.5, recent_total: 1_000.0, direction: :mixed}
      )

    assert {:signal, sig} = Strategy.evaluate(input)
    assert sig.side == "short"
    assert Decimal.to_float(sig.score) >= 0.55
    assert sig.leverage in 1..10
    assert sig.id =~ "BTCUSDT:5m:short:"
  end

  test "rejects signal when trend filter contradicts side" do
    # TF spike says short, but EMAs are stacked bullish (close > ef > es)
    input =
      baseline_input(
        close: 102,
        open: 103,
        ema_fast: 100.0,
        ema_slow: 99.0,
        tf: %{level: 4, avg: 1.0, latest: 4.0},
        oi: %{signal: :longs_trapped, oi_change_pct: 0.05, price_change_pct: -0.03},
        funding: %{z: 2.5, latest: 0.0005, mean: 0.0, stddev: 0.0001}
      )

    assert Strategy.evaluate(input) == :no_signal
  end

  test "respects custom threshold (impossible threshold blocks all signals)" do
    input =
      baseline_input(
        close: 99,
        open: 100,
        ema_fast: 99.5,
        ema_slow: 100.0,
        tf: %{level: 4, avg: 1.0, latest: 4.0},
        oi: %{signal: :longs_trapped, oi_change_pct: 0.05, price_change_pct: -0.03},
        funding: %{z: 2.5, latest: 0.0005, mean: 0.0001, stddev: 0.00016}
      )

    assert Strategy.evaluate(input, threshold: 0.99) == :no_signal
  end
end

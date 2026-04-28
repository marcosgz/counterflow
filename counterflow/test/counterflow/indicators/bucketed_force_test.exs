defmodule Counterflow.Indicators.BucketedForceTest do
  use ExUnit.Case, async: true

  alias Counterflow.Indicators.BucketedForce
  alias Counterflow.Market.Candle

  defp candle(close: c, open: o, volume: v, trades: t) do
    %Candle{
      symbol: "X",
      interval: "1m",
      time: DateTime.utc_now(),
      open: Decimal.new("#{o}"),
      high: Decimal.new("#{c}"),
      low: Decimal.new("#{o}"),
      close: Decimal.new("#{c}"),
      volume: Decimal.new("#{v}"),
      trades: t
    }
  end

  test "level 0 when candle matches the average" do
    candles = for _ <- 1..5, do: candle(close: 100, open: 99, volume: 10, trades: 5)
    result = BucketedForce.calculate(candles, &BucketedForce.body_extractor/1)
    assert result.level == 0
  end

  test "level 5 when latest body is well above the average" do
    # 9 small bodies of 1 + spike of 10 → avg = 1.9, ratio ≈ 5.26 → level 5
    base = for _ <- 1..9, do: candle(close: 100, open: 99, volume: 10, trades: 5)
    spike = candle(close: 110, open: 100, volume: 10, trades: 5)
    candles = base ++ [spike]
    result = BucketedForce.calculate(candles, &BucketedForce.body_extractor/1)
    assert result.level == 5
  end

  test "level 6 when latest body is > 10× the average" do
    # 49 small bodies + 1 spike of 15 → avg ≈ 1.28, ratio ≈ 11.7 → level 6
    base = for _ <- 1..49, do: candle(close: 100, open: 99, volume: 10, trades: 5)
    spike = candle(close: 115, open: 100, volume: 10, trades: 5)
    candles = base ++ [spike]
    result = BucketedForce.calculate(candles, &BucketedForce.body_extractor/1)
    assert result.level == 6
  end

  test "trades_extractor uses trade count" do
    base = for _ <- 1..4, do: candle(close: 100, open: 99, volume: 10, trades: 100)
    spike = candle(close: 100, open: 99, volume: 10, trades: 1500)
    candles = base ++ [spike]
    result = BucketedForce.calculate(candles, &BucketedForce.trades_extractor/1)
    # bodies all zero → avg 0 path; instead this test validates trades extraction:
    # trades [100,100,100,100,1500], avg = 380, ratio = 1500/380 ≈ 3.95 → level 3
    assert result.level == 3
  end
end

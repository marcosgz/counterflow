defmodule Counterflow.Indicators.OIDeltaTest do
  use ExUnit.Case, async: true

  alias Counterflow.Indicators.OIDelta
  alias Counterflow.Market.{Candle, OpenInterest}

  defp oi(value),
    do: %OpenInterest{symbol: "X", time: DateTime.utc_now(), open_interest: Decimal.new("#{value}")}

  defp candle(close),
    do: %Candle{
      symbol: "X",
      interval: "1m",
      time: DateTime.utc_now(),
      open: Decimal.new("#{close}"),
      high: Decimal.new("#{close}"),
      low: Decimal.new("#{close}"),
      close: Decimal.new("#{close}"),
      volume: Decimal.new("0"),
      trades: 0
    }

  test ":stacking when OI rises ≥5% with price flat" do
    oi_series = [oi(100), oi(110)]
    candles = [candle(50), candle(50.1)]
    assert %{signal: :stacking} = OIDelta.calculate(oi_series, candles)
  end

  test ":longs_trapped when OI rises but price falls" do
    oi_series = [oi(100), oi(105)]
    candles = [candle(50), candle(48)]
    assert %{signal: :longs_trapped} = OIDelta.calculate(oi_series, candles)
  end

  test ":neutral when nothing exciting" do
    oi_series = [oi(100), oi(101)]
    candles = [candle(50), candle(50.1)]
    assert %{signal: :neutral} = OIDelta.calculate(oi_series, candles)
  end
end

defmodule Counterflow.Indicators.RSITest do
  use ExUnit.Case, async: true

  alias Counterflow.Indicators.RSI

  test "returns all nils when input < period+1" do
    assert RSI.calculate([1, 2, 3], 14) == [nil, nil, nil]
  end

  test "Wilder's RSI on a known sequence" do
    # Classic textbook example: 14 closing prices from Welles Wilder (1978).
    closes = [
      44.34,
      44.09,
      44.15,
      43.61,
      44.33,
      44.83,
      45.10,
      45.42,
      45.84,
      46.08,
      45.89,
      46.03,
      45.61,
      46.28,
      46.28,
      46.00,
      46.03,
      46.41,
      46.22,
      45.64,
      46.21
    ]

    series = RSI.calculate(closes, 14)
    assert length(series) == length(closes)
    last = List.last(series)
    # npm `technicalindicators` produces ~62.88 on this exact input; accept ±0.5.
    assert_in_delta last, 62.88, 0.5
  end

  test "all-up sequence pegs RSI at 100" do
    rising = Enum.to_list(1..30) |> Enum.map(&(&1 / 1))
    assert RSI.last(rising, 14) == 100.0
  end
end

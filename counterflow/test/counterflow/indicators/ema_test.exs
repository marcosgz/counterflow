defmodule Counterflow.Indicators.EMATest do
  use ExUnit.Case, async: true

  alias Counterflow.Indicators.EMA

  test "returns nils when input shorter than period" do
    assert EMA.calculate([1.0, 2.0], 5) == [nil, nil]
  end

  test "matches reference output to 6 decimals (period=3)" do
    # Reference computed via npm `technicalindicators` ema for period=3 over [10,11,12,13,14]:
    # SMA seed at index 2 = (10+11+12)/3 = 11
    # α = 0.5
    # ema[3] = 13*0.5 + 11*0.5 = 12
    # ema[4] = 14*0.5 + 12*0.5 = 13
    assert [nil, nil, 11.0, 12.0, 13.0] = EMA.calculate([10, 11, 12, 13, 14], 3)
  end

  test "last/2 returns the latest EMA value" do
    assert EMA.last([10, 11, 12, 13, 14], 3) == 13.0
  end
end

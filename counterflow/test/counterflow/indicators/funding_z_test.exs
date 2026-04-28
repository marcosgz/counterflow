defmodule Counterflow.Indicators.FundingZTest do
  use ExUnit.Case, async: true

  alias Counterflow.Indicators.FundingZ
  alias Counterflow.Market.FundingRate

  defp rate(v),
    do: %FundingRate{symbol: "X", time: DateTime.utc_now(), funding_rate: Decimal.from_float(v)}

  test "z is 0 when all rates are equal" do
    series = for _ <- 1..30, do: rate(0.0001)
    assert %{z: 0.0} = FundingZ.calculate(series)
  end

  test "z is positive when latest is above mean" do
    series = (for _ <- 1..29, do: rate(0.0001)) ++ [rate(0.005)]
    %{z: z} = FundingZ.calculate(series)
    assert z > 4.0
  end

  test "empty input returns zeros" do
    assert %{z: 0.0, mean: 0.0} = FundingZ.calculate([])
  end
end

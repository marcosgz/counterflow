defmodule Counterflow.Indicators.FundingZ do
  @moduledoc """
  Z-score of the most recent funding rate against a rolling window
  (typically 30 days × 8h cadence ≈ 90 observations).

  Extreme positive z = longs paying heavily → primed for downside flush.
  Extreme negative z = shorts paying → primed for upside squeeze.
  """

  @type result :: %{z: float(), latest: float(), mean: float(), stddev: float()}

  @spec calculate([Counterflow.Market.FundingRate.t()]) :: result()
  def calculate([]), do: %{z: 0.0, latest: 0.0, mean: 0.0, stddev: 0.0}

  def calculate(series) do
    rates = Enum.map(series, &(&1.funding_rate |> to_float()))
    n = length(rates)
    mean = Enum.sum(rates) / n
    variance = Enum.sum(Enum.map(rates, fn r -> :math.pow(r - mean, 2) end)) / n
    stddev = :math.sqrt(variance)
    latest = List.last(rates)
    # Treat stddev as zero when it's IEEE-noise relative to the mean, otherwise
    # equal-input series produce spurious z-scores from float precision drift.
    effective_zero? = stddev < 1.0e-15 or stddev < abs(mean) * 1.0e-10
    z = if effective_zero?, do: 0.0, else: (latest - mean) / stddev

    %{z: z, latest: latest, mean: mean, stddev: stddev}
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end

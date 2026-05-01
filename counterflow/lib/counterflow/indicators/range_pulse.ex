defmodule Counterflow.Indicators.RangePulse do
  @moduledoc """
  Range volatility bucketed against the symbol's recent distribution.

  Computes `(high - low) / close` for each candle in the window, then
  ranks the latest candle's range against the prior `window_size`-1
  candles by percentile. Returns a 0..6 level using the same thresholds
  as BucketedForce:

      pct < 0.5  → 0  (calm)
      pct < 0.7  → 1
      pct < 0.85 → 2
      pct < 0.92 → 3
      pct < 0.97 → 5
      else       → 6  (extreme)

  Used by the homepage panel's "Range" column to surface symbols with
  unusually wide bars for their own historical norm.
  """

  @spec calculate([Counterflow.Market.Candle.t()]) :: 0..6
  def calculate(candles) when length(candles) < 5, do: 0

  def calculate(candles) do
    ranges =
      Enum.map(candles, fn c ->
        h = to_float(c.high)
        l = to_float(c.low)
        cl = to_float(c.close)
        if cl > 0, do: (h - l) / cl, else: 0.0
      end)

    {prior, [latest]} = Enum.split(ranges, -1)
    sorted = Enum.sort(prior)
    rank = Enum.count(sorted, &(&1 < latest))
    pct = rank / max(length(sorted), 1)

    cond do
      pct < 0.5 -> 0
      pct < 0.7 -> 1
      pct < 0.85 -> 2
      pct < 0.92 -> 3
      pct < 0.97 -> 5
      true -> 6
    end
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(_), do: 0.0
end

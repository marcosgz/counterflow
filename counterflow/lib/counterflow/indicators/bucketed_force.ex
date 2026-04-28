defmodule Counterflow.Indicators.BucketedForce do
  @moduledoc """
  Implements the Price/Volume/Trade Force indicators from the legacy bot.

  For a window of N candles, compute the average of an extracted feature
  (body magnitude / volume / trade count). The "level" of the most recent
  candle is bucketed by how many multiples of the average it represents:

      ratio  > 10×  → level 6
      ratio  >  5×  → level 5
      ratio  >  3×  → level 3
      ratio  >  2×  → level 2
      ratio  >  1×  → level 1
      otherwise     → level 0

  These thresholds match the deobfuscated old-bot Indicator.js. The output is
  a map with the latest level, average, and the latest absolute value.
  """

  @thresholds [{10, 6}, {5, 5}, {3, 3}, {2, 2}, {1, 1}]

  @type extractor :: (Counterflow.Market.Candle.t() -> Decimal.t())
  @type result :: %{level: 0..6, avg: float(), latest: float()}

  @spec calculate([Counterflow.Market.Candle.t()], extractor()) :: result()
  def calculate([], _extractor), do: %{level: 0, avg: 0.0, latest: 0.0}

  def calculate(candles, extractor) do
    values = Enum.map(candles, fn c -> extractor.(c) |> to_float() end)
    avg = Enum.sum(values) / length(values)
    latest = List.last(values)

    %{level: bucket(latest, avg), avg: avg, latest: latest}
  end

  @doc "Body magnitude: |close - open|."
  def body_extractor(c), do: Decimal.abs(Decimal.sub(c.close, c.open))

  @doc "Volume: candle.volume."
  def volume_extractor(c), do: c.volume

  @doc "Trade count: candle.trades (returned as Decimal for type uniformity)."
  def trades_extractor(c), do: Decimal.new(c.trades || 0)

  defp bucket(value, avg) when avg > 0 do
    Enum.find_value(@thresholds, 0, fn {mult, level} ->
      if value > avg * mult, do: level
    end)
  end

  defp bucket(_v, _avg), do: 0

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end

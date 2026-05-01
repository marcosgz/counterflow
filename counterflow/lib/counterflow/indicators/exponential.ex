defmodule Counterflow.Indicators.Exponential do
  @moduledoc """
  Momentum-strength indicator. Returns a signed integer roughly in
  [-300, +300] expressing how far the latest close is from its 50-period
  simple moving average, in basis points:

      exp = (close - SMA(close, 50)) / SMA(close, 50) * 10_000

  Two flavors exposed:

    * `calculate/1` — pass a list of closes (any series). Used for
      EXP-vs-USD where the symbol's native quote is already USDT.
    * `calculate_relative/2` — pass two equal-length lists of closes
      (symbol, base) and the indicator runs on the ratio series. Used
      for EXP-vs-BTC: relative strength of `symbol/btc` over the window.

  Both return `0` when input is too short (< 50 closes).
  """

  @period 50

  @spec calculate([number() | Decimal.t()]) :: integer()
  def calculate(closes) when is_list(closes) do
    floats = Enum.map(closes, &to_float/1)
    do_calc(floats)
  end

  @spec calculate_relative([number() | Decimal.t()], [number() | Decimal.t()]) :: integer()
  def calculate_relative(symbol_closes, base_closes)
      when is_list(symbol_closes) and is_list(base_closes) do
    n = min(length(symbol_closes), length(base_closes))
    sym = symbol_closes |> Enum.take(-n) |> Enum.map(&to_float/1)
    bas = base_closes |> Enum.take(-n) |> Enum.map(&to_float/1)

    ratios =
      Enum.zip(sym, bas)
      |> Enum.map(fn {s, b} -> if b > 0, do: s / b, else: 0.0 end)

    do_calc(ratios)
  end

  defp do_calc(floats) when length(floats) < @period, do: 0

  defp do_calc(floats) do
    last = List.last(floats)
    window = Enum.take(floats, -@period)
    sma = Enum.sum(window) / @period

    if sma > 0 do
      round((last - sma) / sma * 10_000)
    else
      0
    end
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(_), do: 0.0
end

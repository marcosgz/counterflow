defmodule Counterflow.Indicators.EMA do
  @moduledoc """
  Exponential Moving Average.

  Reference formula:
      α = 2 / (period + 1)
      EMA[period - 1] = SMA(values[0..period-1])
      EMA[i]          = values[i] * α + EMA[i-1] * (1 - α)

  Inputs are floats (use `Decimal.to_float/1` upstream). Output: list of floats
  same length as input, with the first `period - 1` slots filled with `nil`.
  """

  @spec calculate([number()], pos_integer()) :: [float() | nil]
  def calculate(values, period) when is_list(values) and is_integer(period) and period > 0 do
    values = Enum.map(values, &to_float/1)

    cond do
      length(values) < period ->
        List.duplicate(nil, length(values))

      true ->
        alpha = 2.0 / (period + 1)
        {seed, rest} = Enum.split(values, period)
        sma = Enum.sum(seed) / period

        emas =
          rest
          |> Enum.scan(sma, fn x, prev -> x * alpha + prev * (1.0 - alpha) end)

        List.duplicate(nil, period - 1) ++ [sma | emas]
    end
  end

  @doc "Convenience: latest EMA value, or nil if input shorter than `period`."
  def last(values, period) do
    values |> calculate(period) |> List.last()
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end

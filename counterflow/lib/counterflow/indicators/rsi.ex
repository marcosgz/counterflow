defmodule Counterflow.Indicators.RSI do
  @moduledoc """
  Relative Strength Index (Wilder's smoothing).

  RSI = 100 - 100 / (1 + RS)
  RS  = avg_gain / avg_loss

  Initial avg_gain/avg_loss = simple mean of first `period` gains/losses.
  Subsequent: Wilder's smoothing → ((prev_avg * (period-1)) + current) / period.
  """

  @spec calculate([number()], pos_integer()) :: [float() | nil]
  def calculate(values, period \\ 14) when is_list(values) and period > 0 do
    values = Enum.map(values, &to_float/1)

    if length(values) < period + 1 do
      List.duplicate(nil, length(values))
    else
      changes =
        values
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)

      {init_changes, rest_changes} = Enum.split(changes, period)
      init_gains = Enum.sum(Enum.map(init_changes, &max(&1, 0))) / period
      init_losses = Enum.sum(Enum.map(init_changes, &(-min(&1, 0)))) / period

      {avg_gain_series, avg_loss_series} =
        Enum.reduce(rest_changes, {[init_gains], [init_losses]}, fn ch, {gs, ls} ->
          gain = max(ch, 0)
          loss = -min(ch, 0)
          new_g = (hd(gs) * (period - 1) + gain) / period
          new_l = (hd(ls) * (period - 1) + loss) / period
          {[new_g | gs], [new_l | ls]}
        end)

      gains = Enum.reverse(avg_gain_series)
      losses = Enum.reverse(avg_loss_series)

      rsi_series =
        Enum.zip_with(gains, losses, fn g, l ->
          cond do
            l == 0 and g == 0 -> 50.0
            l == 0 -> 100.0
            true ->
              rs = g / l
              100.0 - 100.0 / (1.0 + rs)
          end
        end)

      List.duplicate(nil, period) ++ rsi_series
    end
  end

  def last(values, period \\ 14) do
    values |> calculate(period) |> List.last()
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end

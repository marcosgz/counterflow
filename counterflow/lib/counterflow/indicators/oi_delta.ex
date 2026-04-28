defmodule Counterflow.Indicators.OIDelta do
  @moduledoc """
  Open-interest change combined with price action over the same window,
  classified into one of:

    :stacking      — OI ↑, price flat   (positions building, squeeze setup)
    :unwinding     — OI ↓, price flat
    :longs_trapped — OI ↑, price ↓      (longs adding into weakness)
    :shorts_trapped — OI ↑, price ↑     (shorts adding into strength)
    :longs_chasing — OI ↑, price ↑      (capitulation buys)
    :shorts_chasing — OI ↑, price ↓
    :neutral

  Counterflow strategy looks for `:longs_trapped` and `:stacking` as primary
  smart-money setups (longs about to be flushed for liquidation harvest).
  """

  @type signal ::
          :stacking
          | :unwinding
          | :longs_trapped
          | :shorts_trapped
          | :longs_chasing
          | :shorts_chasing
          | :neutral

  @type result :: %{
          signal: signal(),
          oi_change_pct: float(),
          price_change_pct: float()
        }

  @spec calculate([Counterflow.Market.OpenInterest.t()], [Counterflow.Market.Candle.t()]) ::
          result()
  def calculate([], _candles), do: empty()
  def calculate(_oi, []), do: empty()

  def calculate(oi_series, candle_series) when is_list(oi_series) and is_list(candle_series) do
    {first_oi, last_oi} = endpoints(oi_series, & &1.open_interest)
    {first_price, last_price} = endpoints(candle_series, & &1.close)

    oi_pct = pct_change(first_oi, last_oi)
    price_pct = pct_change(first_price, last_price)

    %{signal: classify(oi_pct, price_pct), oi_change_pct: oi_pct, price_change_pct: price_pct}
  end

  defp empty, do: %{signal: :neutral, oi_change_pct: 0.0, price_change_pct: 0.0}

  defp endpoints(list, getter) do
    {getter.(List.first(list)) |> to_float(), getter.(List.last(list)) |> to_float()}
  end

  defp pct_change(first, _last) when first <= 0, do: 0.0
  defp pct_change(first, last), do: (last - first) / first

  defp classify(oi, price) do
    cond do
      oi > 0.05 and abs(price) < 0.01 -> :stacking
      oi < -0.05 and abs(price) < 0.01 -> :unwinding
      oi > 0.03 and price < -0.02 -> :longs_trapped
      oi > 0.03 and price > 0.02 -> :longs_chasing
      oi < -0.03 and price > 0.02 -> :shorts_chasing
      oi < -0.03 and price < -0.02 -> :shorts_trapped
      true -> :neutral
    end
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end

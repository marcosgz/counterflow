defmodule Counterflow.Indicators.LiquidationPulse do
  @moduledoc """
  Liquidation-cluster intensity: rolling sum of liquidation notional over the
  last `window_minutes`, ranked against the 30-day distribution of equivalent
  windows.

  Returns:
    * percentile  — 0.0..1.0
    * recent_total — Decimal sum of last window's liquidation notional
    * direction   — :longs_blown | :shorts_blown | :mixed
  """

  @default_window_minutes 15

  @type direction :: :longs_blown | :shorts_blown | :mixed | :none
  @type result :: %{
          percentile: float(),
          recent_total: float(),
          direction: direction()
        }

  @spec calculate([Counterflow.Market.Liquidation.t()], keyword()) :: result()
  def calculate(liqs, opts \\ [])
  def calculate([], _opts), do: %{percentile: 0.0, recent_total: 0.0, direction: :none}

  def calculate(liqs, opts) do
    window_min = Keyword.get(opts, :window_minutes, @default_window_minutes)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -window_min * 60, :second)

    {recent, historical_total} = split(liqs, cutoff)
    recent_total = sum_notional(recent)

    historical_buckets =
      historical_total
      |> Enum.group_by(&time_bucket(&1.time, window_min * 60))
      |> Map.values()
      |> Enum.map(&sum_notional/1)
      |> Enum.sort()

    percentile = percentile_of(recent_total, historical_buckets)
    direction = direction_of(recent)

    %{percentile: percentile, recent_total: recent_total, direction: direction}
  end

  defp split(liqs, cutoff) do
    Enum.split_with(liqs, fn l -> DateTime.compare(l.time, cutoff) == :gt end)
  end

  defp sum_notional(liqs) do
    Enum.reduce(liqs, 0.0, fn l, acc ->
      acc + to_float(l.price) * to_float(l.qty)
    end)
  end

  defp time_bucket(%DateTime{} = dt, seconds) do
    unix = DateTime.to_unix(dt)
    div(unix, seconds) * seconds
  end

  defp percentile_of(_value, []), do: 1.0

  defp percentile_of(value, sorted) do
    rank = Enum.count(sorted, &(&1 < value))
    rank / length(sorted)
  end

  defp direction_of(liqs) do
    {longs, shorts} =
      Enum.reduce(liqs, {0.0, 0.0}, fn l, {lo, sh} ->
        notional = to_float(l.price) * to_float(l.qty)

        case l.side do
          # On Binance, side="SELL" liquidations are LONG positions being closed
          "SELL" -> {lo + notional, sh}
          "BUY" -> {lo, sh + notional}
          _ -> {lo, sh}
        end
      end)

    cond do
      longs == 0 and shorts == 0 -> :none
      longs > 2 * shorts -> :longs_blown
      shorts > 2 * longs -> :shorts_blown
      true -> :mixed
    end
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end

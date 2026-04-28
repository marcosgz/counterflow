defmodule Counterflow.Indicators.LSRSignal do
  @moduledoc """
  Long/Short Ratio derived signals — kept from the legacy bot but
  down-weighted in the modern composite scorer because the edge has decayed.

  Computes RSI(14) + EMA(7) + EMA(25) over the LSR series itself, plus the
  simple "extreme" flag at RSI > 70 / < 30 with EMA stack alignment.
  """

  alias Counterflow.Indicators.{EMA, RSI}

  @type extreme :: :longs_overheated | :shorts_overheated | :neutral
  @type result :: %{
          raw: float() | nil,
          rsi: float() | nil,
          ema_fast: float() | nil,
          ema_slow: float() | nil,
          extreme: extreme()
        }

  @spec calculate([Counterflow.Market.LongShortRatio.t()]) :: result()
  def calculate([]), do: %{raw: nil, rsi: nil, ema_fast: nil, ema_slow: nil, extreme: :neutral}

  def calculate(series) do
    values = Enum.map(series, &(&1.ls_ratio |> to_float()))
    raw = List.last(values)
    rsi = RSI.last(values, 14)
    ema_fast = EMA.last(values, 7)
    ema_slow = EMA.last(values, 25)

    %{raw: raw, rsi: rsi, ema_fast: ema_fast, ema_slow: ema_slow, extreme: classify(raw, rsi, ema_fast, ema_slow)}
  end

  defp classify(raw, rsi, ef, es)
       when is_number(rsi) and is_number(ef) and is_number(es) and is_number(raw) do
    cond do
      rsi > 70 and raw > ef and ef > es -> :longs_overheated
      rsi < 30 and raw < ef and ef < es -> :shorts_overheated
      true -> :neutral
    end
  end

  defp classify(_, _, _, _), do: :neutral

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end

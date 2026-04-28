defmodule Counterflow.Strategy.Input do
  @moduledoc """
  Bundle of indicator outputs and raw market state passed to a Strategy
  implementation. Constructed by `Counterflow.Strategy.Pipeline` from the
  most recent hypertable rows for a (symbol, interval).
  """

  defstruct [
    :symbol,
    :interval,
    :candle,
    :candles,
    :tf,
    :pf,
    :vf,
    :ema_fast,
    :ema_slow,
    :ema_very_slow,
    :oi_delta,
    :funding_z,
    :liq_pulse,
    :lsr_signal,
    :now
  ]

  @type t :: %__MODULE__{}
end

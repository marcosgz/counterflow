defmodule Counterflow.Backtest.Metrics do
  @moduledoc """
  Compute simple performance metrics from a list of signal/outcome pairs.

  Outcomes are computed externally (e.g. by walking forward through the
  candle stream after the signal time). For Phase 7's first cut we expose
  the helpers the caller needs: win-rate, profit factor, R-multiple stats.
  """

  @type outcome :: %{
          hit_tp1: boolean(),
          hit_tp2: boolean(),
          hit_sl: boolean(),
          r_multiple: float(),
          peak_R: float(),
          trough_R: float()
        }

  @type signal_with_outcome :: {Counterflow.Strategy.Signal.t(), outcome()}

  @spec summarize([signal_with_outcome()]) :: map()
  def summarize([]) do
    %{
      total: 0,
      win_rate: 0.0,
      profit_factor: 0.0,
      avg_r: 0.0,
      sum_r: 0.0,
      max_drawdown_r: 0.0
    }
  end

  def summarize(pairs) do
    total = length(pairs)
    rs = Enum.map(pairs, fn {_s, %{r_multiple: r}} -> r end)

    wins = Enum.filter(rs, &(&1 > 0))
    losses = Enum.filter(rs, &(&1 < 0))

    win_rate = length(wins) / total
    avg_r = Enum.sum(rs) / total

    profit_factor =
      if losses == [] do
        if wins == [], do: 0.0, else: 1_000_000.0
      else
        Enum.sum(wins) / abs(Enum.sum(losses))
      end

    {_running, max_dd} =
      Enum.reduce(rs, {0.0, 0.0}, fn r, {running, peak_dd} ->
        new_running = running + r
        {new_running, max(peak_dd, -new_running)}
      end)

    %{
      total: total,
      win_rate: win_rate,
      profit_factor: profit_factor,
      avg_r: avg_r,
      sum_r: Enum.sum(rs),
      max_drawdown_r: max_dd
    }
  end

  @doc """
  Walk forward through `future_candles` from a signal and determine which
  bracket (tp1, tp2, sl) hit first within `ttl_minutes`.
  """
  @spec evaluate_outcome(Counterflow.Strategy.Signal.t(), [Counterflow.Market.Candle.t()]) :: outcome()
  def evaluate_outcome(sig, future_candles) do
    direction = if sig.side == "long", do: 1.0, else: -1.0
    entry = Decimal.to_float(sig.price)
    sl = Decimal.to_float(sig.sl)
    tp1 = Decimal.to_float(sig.tp1)
    tp2 = Decimal.to_float(sig.tp2)
    r = abs(entry - sl)

    cutoff =
      DateTime.add(sig.generated_at, sig.ttl_minutes * 60, :second)

    relevant = Enum.take_while(future_candles, fn c -> DateTime.compare(c.time, cutoff) == :lt end)

    {hit_sl?, hit_tp1?, hit_tp2?, peak, trough} =
      Enum.reduce(relevant, {false, false, false, 0.0, 0.0}, fn c, {sl?, tp1?, tp2?, peak, trough} ->
        high = Decimal.to_float(c.high)
        low = Decimal.to_float(c.low)
        max_excursion = (max(high, low) - entry) * direction / r
        min_excursion = (min(high, low) - entry) * direction / r

        sl_hit = if direction == 1.0, do: low <= sl, else: high >= sl
        tp1_hit = if direction == 1.0, do: high >= tp1, else: low <= tp1
        tp2_hit = if direction == 1.0, do: high >= tp2, else: low <= tp2

        {
          sl? or sl_hit,
          tp1? or tp1_hit,
          tp2? or tp2_hit,
          max(peak, max_excursion),
          min(trough, min_excursion)
        }
      end)

    r_multiple =
      cond do
        hit_sl? and not hit_tp1? -> -1.0
        hit_tp2? -> 2.0
        hit_tp1? -> 1.0
        true -> 0.0
      end

    %{
      hit_tp1: hit_tp1?,
      hit_tp2: hit_tp2?,
      hit_sl: hit_sl?,
      r_multiple: r_multiple,
      peak_R: peak,
      trough_R: trough
    }
  end
end

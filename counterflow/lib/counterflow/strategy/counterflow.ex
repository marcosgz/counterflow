defmodule Counterflow.Strategy.Counterflow do
  @moduledoc """
  The Counterflow strategy: composite-weighted scorer combining TF spike,
  OI divergence, funding z-score, liquidation pulse, CVD divergence, and
  LSR extreme. Emits a signal when score ≥ threshold AND the trend filter
  is satisfied for the chosen side.

  See docs/plan/04-strategy-signals.md for the full design and rationale.
  """

  @behaviour Counterflow.Strategy

  alias Counterflow.Strategy.{Input, Signal}

  @default_weights %{
    tf_spike: 0.25,
    oi_divergence: 0.20,
    funding_z: 0.15,
    liquidation: 0.15,
    cvd_divergence: 0.15,
    lsr_extreme: 0.10
  }

  @default_threshold 0.55
  @default_ttl_minutes 120

  @impl true
  def evaluate(%Input{} = input, opts \\ []) do
    weights = Keyword.get(opts, :weights, @default_weights)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    ttl_minutes = Keyword.get(opts, :ttl_minutes, @default_ttl_minutes)

    case directional_bias(input) do
      :neutral ->
        :no_signal

      side ->
        components = score_components(input, side)
        score = weighted_sum(components, weights)

        if score >= threshold and trend_filter_ok?(input, side) do
          {:signal, build_signal(input, side, score, components, ttl_minutes)}
        else
          :no_signal
        end
    end
  end

  # ── direction selection ─────────────────────────────────────

  defp directional_bias(%Input{} = i) do
    candidates =
      []
      |> add_if(tf_bias(i))
      |> add_if(funding_bias(i))
      |> add_if(liquidation_bias(i))
      |> add_if(oi_bias(i))
      |> Enum.uniq()

    case candidates do
      [side] -> side
      [_, _ | _] -> :neutral
      [] -> :neutral
    end
  end

  defp add_if(list, :neutral), do: list
  defp add_if(list, side), do: [side | list]

  defp tf_bias(%Input{tf: %{level: l}, candle: c}) when is_integer(l) and l >= 3 do
    if Decimal.gt?(c.close, c.open), do: :long, else: :short
  end

  defp tf_bias(_), do: :neutral

  # Extreme funding: contra side
  defp funding_bias(%Input{funding_z: %{z: z}}) when is_number(z) do
    cond do
      z > 2.0 -> :short
      z < -2.0 -> :long
      true -> :neutral
    end
  end

  defp funding_bias(_), do: :neutral

  defp liquidation_bias(%Input{liq_pulse: %{percentile: p, direction: dir}})
       when is_number(p) and p > 0.9 do
    case dir do
      :longs_blown -> :long
      :shorts_blown -> :short
      _ -> :neutral
    end
  end

  defp liquidation_bias(_), do: :neutral

  defp oi_bias(%Input{oi_delta: %{signal: :longs_trapped}}), do: :short
  defp oi_bias(%Input{oi_delta: %{signal: :shorts_trapped}}), do: :long
  defp oi_bias(_), do: :neutral

  # ── score components (each in [-1.0, 1.0]) ──────────────────

  defp score_components(%Input{} = i, side) do
    %{
      tf_spike: tf_component(i, side),
      oi_divergence: oi_component(i, side),
      funding_z: funding_component(i, side),
      liquidation: liquidation_component(i, side),
      cvd_divergence: 0.0,
      lsr_extreme: lsr_component(i, side)
    }
  end

  defp tf_component(%Input{tf: %{level: l}, candle: c}, :long) when is_integer(l) do
    if Decimal.gt?(c.close, c.open), do: l / 6.0, else: -l / 6.0
  end

  defp tf_component(%Input{tf: %{level: l}, candle: c}, :short) when is_integer(l) do
    if Decimal.lt?(c.close, c.open), do: l / 6.0, else: -l / 6.0
  end

  defp tf_component(_, _), do: 0.0

  defp oi_component(%Input{oi_delta: %{signal: sig}}, :long) do
    case sig do
      # LONG side does NOT want longs trapped
      :longs_trapped -> -1.0
      :shorts_trapped -> 1.0
      :stacking -> 0.3
      :unwinding -> -0.3
      _ -> 0.0
    end
  end

  defp oi_component(%Input{oi_delta: %{signal: sig}}, :short) do
    case sig do
      :longs_trapped -> 1.0
      :shorts_trapped -> -1.0
      :stacking -> -0.3
      _ -> 0.0
    end
  end

  defp oi_component(_, _), do: 0.0

  defp funding_component(%Input{funding_z: %{z: z}}, :long) when is_number(z) do
    cond do
      z < -2.0 -> 1.0
      z > 2.0 -> -1.0
      true -> -z / 2.0
    end
  end

  defp funding_component(%Input{funding_z: %{z: z}}, :short) when is_number(z) do
    cond do
      z > 2.0 -> 1.0
      z < -2.0 -> -1.0
      true -> z / 2.0
    end
  end

  defp funding_component(_, _), do: 0.0

  defp liquidation_component(%Input{liq_pulse: %{percentile: p, direction: dir}}, side)
       when is_number(p) do
    sign =
      case {dir, side} do
        {:longs_blown, :long} -> 1.0
        {:shorts_blown, :short} -> 1.0
        {:longs_blown, :short} -> -0.5
        {:shorts_blown, :long} -> -0.5
        _ -> 0.0
      end

    sign * min(p, 1.0)
  end

  defp liquidation_component(_, _), do: 0.0

  defp lsr_component(%Input{lsr_signal: %{extreme: ex}}, :short) do
    case ex do
      :longs_overheated -> 1.0
      :shorts_overheated -> -0.5
      _ -> 0.0
    end
  end

  defp lsr_component(%Input{lsr_signal: %{extreme: ex}}, :long) do
    case ex do
      :shorts_overheated -> 1.0
      :longs_overheated -> -0.5
      _ -> 0.0
    end
  end

  defp lsr_component(_, _), do: 0.0

  defp weighted_sum(components, weights) do
    Enum.reduce(components, 0.0, fn {k, v}, acc ->
      acc + Map.get(weights, k, 0.0) * v
    end)
  end

  # ── trend filter ────────────────────────────────────────────

  defp trend_filter_ok?(%Input{candle: c, ema_fast: ef, ema_slow: es}, :long)
       when is_number(ef) and is_number(es) do
    Decimal.to_float(c.close) > ef and ef >= es
  end

  defp trend_filter_ok?(%Input{candle: c, ema_fast: ef, ema_slow: es}, :short)
       when is_number(ef) and is_number(es) do
    Decimal.to_float(c.close) < ef and ef <= es
  end

  defp trend_filter_ok?(%Input{candle: c, ema_fast: ef}, :long) when is_number(ef) do
    Decimal.to_float(c.close) > ef
  end

  defp trend_filter_ok?(%Input{candle: c, ema_fast: ef}, :short) when is_number(ef) do
    Decimal.to_float(c.close) < ef
  end

  defp trend_filter_ok?(_, _), do: false

  # ── signal construction ─────────────────────────────────────

  defp build_signal(%Input{} = i, side, score, components, ttl_minutes) do
    now = i.now || DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {sl, tp1, tp2} = brackets(i, side)
    leverage = suggest_leverage(i.candle.close, sl)

    %Signal{
      id: Signal.build_id(i.symbol, i.interval, Atom.to_string(side), now),
      symbol: i.symbol,
      interval: i.interval,
      side: Atom.to_string(side),
      score: Decimal.from_float(Float.round(score, 4)),
      components: components,
      price: i.candle.close,
      leverage: leverage,
      sl: sl,
      tp1: tp1,
      tp2: tp2,
      ttl_minutes: ttl_minutes,
      notes: notes_for(components),
      generated_at: now
    }
  end

  defp brackets(%Input{candles: cs, candle: c}, :long) do
    last3 = cs |> Enum.take(-3)
    low = last3 |> Enum.map(& &1.low) |> Enum.min_by(&Decimal.to_float/1)
    sl = Decimal.mult(low, Decimal.from_float(0.999))
    r = Decimal.sub(c.close, sl)
    {sl, Decimal.add(c.close, r), Decimal.add(c.close, Decimal.mult(r, Decimal.new(2)))}
  end

  defp brackets(%Input{candles: cs, candle: c}, :short) do
    last3 = cs |> Enum.take(-3)
    high = last3 |> Enum.map(& &1.high) |> Enum.max_by(&Decimal.to_float/1)
    sl = Decimal.mult(high, Decimal.from_float(1.001))
    r = Decimal.sub(sl, c.close)
    {sl, Decimal.sub(c.close, r), Decimal.sub(c.close, Decimal.mult(r, Decimal.new(2)))}
  end

  defp suggest_leverage(price, sl) do
    diff = Decimal.abs(Decimal.sub(price, sl)) |> Decimal.to_float()
    p = Decimal.to_float(price)
    r_pct = if p > 0, do: diff / p, else: 0.0

    cond do
      r_pct < 0.005 -> 10
      r_pct < 0.01 -> 5
      r_pct < 0.02 -> 3
      true -> 2
    end
  end

  defp notes_for(components) do
    components
    |> Enum.filter(fn {_k, v} -> abs(v) > 0.3 end)
    |> Enum.map(fn {k, v} -> "#{k}=#{Float.round(v, 2)}" end)
  end
end

# Phase 3 — Indicators Engine

**Goal:** Pure-function indicator library that takes in time-ordered structs and produces tagged values, ported from the old bot's PF/VF/TF and extended with modern signals (OI delta, funding-z, CVD, liquidation pulse, book imbalance).

**Exit criteria:**
- Parity tests prove EMA/RSI/MACD output matches the npm `technicalindicators` reference to ≥ 4 decimal places.
- PF/VF/TF output matches manually-computed values from sample candles.
- Backfill of 30 days × 50 symbols × 5 intervals through indicators completes in < 10 min wall-clock.
- Indicator values materialized in `indicator_values` hypertable for fast LiveView queries.

## 3.1 Module shape

`Counterflow.Indicators` is **pure functions only** — no GenServer, no DB, no Phoenix. This is critical for testability and for reuse from the backtester (Phase 7) which calls them with historical data instead of live.

```elixir
defmodule Counterflow.Indicators do
  alias Counterflow.Indicators.{EMA, RSI, MACD, PF, VF, TF, OIDelta, FundingZ, CVD, LiquidationPulse, BookImbalance}

  # Each indicator module exposes:
  #   calculate(input :: list, opts :: keyword) :: result :: %{...}
  # where result has at minimum :value (the latest reading) and :series (full series for charting).
end
```

Inputs: lists of structs from Ecto schemas (`%Candle{}`, `%OpenInterest{}`, etc.) ordered oldest-to-newest. Indicators do not mutate or reorder.

Output convention: every indicator returns
```elixir
%{
  name: :tf,
  value: 3,                    # latest scalar/level
  series: [%{time: ~U[...], value: 3}, ...],
  meta: %{period: 720, level_thresholds: [1, 2, 3, 5, 10]}
}
```

## 3.2 Ported from old bot (formulas re-derived from deobfuscated `Indicator.js`)

### Price Force (PF)
```elixir
defmodule Counterflow.Indicators.PF do
  @thresholds [{10, 6}, {5, 5}, {3, 3}, {2, 2}, {1, 1}]   # {multiplier, level}, descending

  def calculate(candles, _opts \\ []) do
    bodies = Enum.map(candles, fn c -> Decimal.abs(Decimal.sub(c.close, c.open)) end)
    avg = bodies |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
                 |> Decimal.div(Decimal.new(length(bodies)))
    last = List.last(bodies)
    %{
      name: :pf,
      value: bucket(last, avg),
      avg: avg,
      pips: last,
      series: pair_series(candles, bodies, avg)
    }
  end

  defp bucket(value, avg) do
    Enum.find_value(@thresholds, 0, fn {mult, level} ->
      if Decimal.gt?(value, Decimal.mult(avg, Decimal.new(mult))), do: level
    end)
  end
end
```

VF and TF are structurally identical — just feed `volume` or `trades` instead of body size. Refactor into a shared `BucketedForce.calculate/3` taking an extractor function.

### EMA / RSI / MACD
Use a thin wrapper around hand-written implementations (not a dep — `technicalindicators` Elixir libs are unmaintained). Validation: capture the npm `technicalindicators` output for fixed input sequences, store as JSON fixtures in `test/fixtures/ti/`, assert parity in tests.

EMA reference formula:
```
α = 2 / (period + 1)
EMA[0] = SMA(values[0..period-1])
EMA[i] = values[i] * α + EMA[i-1] * (1 - α)
```

Use `Decimal` for prices but **`:math` floats** internally for EMA/RSI/MACD (the recursive multiplication compounds Decimal precision cost; npm `technicalindicators` uses floats too, so parity requires floats). Convert back to Decimal at boundaries.

## 3.3 New indicators

### OIDelta
```elixir
def calculate(oi_series, candles, opts) do
  window = Keyword.get(opts, :window, 12)   # 12 × 5m = 1h
  oi_pairs = oi_series |> Enum.take(-window) |> Enum.map(& &1.open_interest)
  oi_change_pct = pct_change(List.first(oi_pairs), List.last(oi_pairs))

  price_pairs = candles |> Enum.take(-window) |> Enum.map(& &1.close)
  price_change_pct = pct_change(List.first(price_pairs), List.last(price_pairs))

  divergence =
    cond do
      oi_change_pct > 0.05 and abs(price_change_pct) < 0.01 -> :stacking         # OI ↑, price flat
      oi_change_pct < -0.05 and abs(price_change_pct) < 0.01 -> :unwinding       # OI ↓, price flat
      oi_change_pct > 0.03 and price_change_pct < -0.02 -> :longs_trapped        # OI ↑, price ↓
      oi_change_pct > 0.03 and price_change_pct > 0.02 -> :longs_chasing
      true -> :neutral
    end

  %{name: :oi_delta, value: divergence, oi_change_pct: oi_change_pct, price_change_pct: price_change_pct, series: ...}
end
```

`:stacking` and `:longs_trapped` are the strongest counter-trend setups.

### FundingZ
30-day rolling z-score of the funding rate. Extreme +z (e.g. > 2.5) → longs paying heavily → primed for flush down. Extreme -z → shorts paying → primed for squeeze up.

```elixir
def calculate(funding_series, _opts) do
  # funding_series: [%FundingRate{time, funding_rate}, ...] last 30 days
  rates = Enum.map(funding_series, & &1.funding_rate |> Decimal.to_float())
  mean = Enum.sum(rates) / length(rates)
  variance = Enum.reduce(rates, 0, fn r, acc -> acc + :math.pow(r - mean, 2) end) / length(rates)
  stddev = :math.sqrt(variance)
  latest = List.last(rates)
  z = if stddev > 0, do: (latest - mean) / stddev, else: 0
  %{name: :funding_z, value: z, latest_rate: latest, mean: mean, stddev: stddev}
end
```

### CVD (Cumulative Volume Delta)
From `cvd_bars` already aggregated in Phase 2.
```elixir
def calculate(cvd_bars, _opts) do
  series = Enum.scan(cvd_bars, Decimal.new(0), fn bar, acc ->
    delta = Decimal.sub(bar.taker_buy_quote, bar.taker_sell_quote)
    Decimal.add(acc, delta)
  end)
  %{name: :cvd, value: List.last(series), series: pair_series(cvd_bars, series)}
end
```

Divergence detection (consumed by strategy in Phase 4): price making new high but CVD not = sellers absorbing = potential reversal.

### LiquidationPulse
Rolling sum of liquidation notional over last N minutes, expressed as percentile rank vs the symbol's 30d distribution. > 95th percentile = unusual cascade.

```elixir
def calculate(liquidations, opts) do
  window = Keyword.get(opts, :window_minutes, 15)
  cutoff = DateTime.add(DateTime.utc_now(), -window * 60, :second)

  recent_total =
    liquidations
    |> Enum.filter(&DateTime.compare(&1.time, cutoff) == :gt)
    |> Enum.reduce(Decimal.new(0), fn l, acc -> Decimal.add(acc, l.notional) end)

  historical_buckets =
    liquidations
    |> Enum.group_by(&time_bucket(&1.time, window * 60))
    |> Map.values()
    |> Enum.map(&total_notional/1)
    |> Enum.sort()

  rank = Enum.find_index(historical_buckets, &Decimal.lt?(&1, recent_total))
  percentile = if rank, do: rank / length(historical_buckets), else: 1.0

  %{
    name: :liquidation_pulse,
    value: percentile,
    recent_total: recent_total,
    direction: dominant_side(liquidations, cutoff)
  }
end
```

`dominant_side/2`: returns `:longs_blown` (more SELL liqs) or `:shorts_blown` (more BUY liqs).

### BookImbalance
From the partial book depth ws (watchlist only). Cumulative bid quantity in top N levels vs ask quantity.
```elixir
def calculate(%{bids: bids, asks: asks}, opts) do
  levels = Keyword.get(opts, :levels, 10)
  bid_qty = bids |> Enum.take(levels) |> Enum.map(& &1.qty) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  ask_qty = asks |> Enum.take(levels) |> Enum.map(& &1.qty) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  total = Decimal.add(bid_qty, ask_qty)
  imbalance = if Decimal.gt?(total, 0), do: Decimal.sub(bid_qty, ask_qty) |> Decimal.div(total), else: Decimal.new(0)
  %{name: :book_imbalance, value: imbalance, bid_qty: bid_qty, ask_qty: ask_qty}
end
```

Range -1.0 (all asks) to +1.0 (all bids). Watch for sustained extremes (potential spoofing if the imbalance vanishes when price approaches).

## 3.4 LSR-derived indicators (kept from old bot)

```elixir
def lsr_with_emas(lsr_series) do
  values = Enum.map(lsr_series, & &1.ls_ratio |> Decimal.to_float())
  %{
    raw: List.last(values),
    rsi: RSI.calculate(values, period: 14).value,
    ema_fast: EMA.calculate(values, period: 7).value,
    ema_slow: EMA.calculate(values, period: 25).value
  }
end
```

The strategy module (Phase 4) uses crossover patterns: `raw > ema_fast > ema_slow` + `RSI > 70` = "longs piling on, exhausted" → contra short signal.

## 3.5 Materialization (`indicator_values` table)

```sql
CREATE TABLE indicator_values (
  symbol     TEXT NOT NULL,
  interval   TEXT NOT NULL,           -- bar interval the indicator was computed on
  indicator  TEXT NOT NULL,           -- 'pf' | 'vf' | 'tf' | 'ema7' | ...
  time       TIMESTAMPTZ NOT NULL,    -- candle close time
  value      JSONB NOT NULL,          -- the indicator's full result map
  PRIMARY KEY (symbol, interval, indicator, time)
);
SELECT create_hypertable('indicator_values', 'time', chunk_time_interval => INTERVAL '7 days');
```

JSONB chosen over typed columns because indicator return shapes vary (PF returns `{level, avg, pips}`, EMA returns scalar, OIDelta returns enum + numbers). LiveView reads the latest row per (symbol, interval, indicator) for charts.

`Counterflow.Indicators.Materializer` (Oban worker, queue `:indicators`, concurrency 4):
- Triggered by `[:counterflow, :candle, :closed]` telemetry handler → enqueue per-symbol per-interval job.
- Loads last N rows from source hypertable, runs all indicators, upserts into `indicator_values`.
- Idempotent (upsert on conflict).

## 3.6 Backfill orchestration

`mix counterflow.backfill_indicators --symbol BTCUSDT --interval 5m --days 30` Mix task:
- Reads candles + OI + LSR + funding + cvd_bars for the window.
- Walks forward bar-by-bar, computing all indicators, persisting to `indicator_values`.
- Progress reporting via `IO.write` + telemetry.
- Default: enqueue Oban jobs for the watchlist on first promotion.

Performance budget: 30d × 50 symbols × 5 intervals × ~12 indicators ≈ 2.6M rows. With batched inserts (`Repo.insert_all/3` in chunks of 1000) and 4 concurrent jobs, target < 10 min.

## 3.7 Parity test fixtures

`test/fixtures/ti/` directory contains JSON files like:
```json
{
  "indicator": "ema",
  "period": 7,
  "input": [44.34, 44.09, 44.15, 43.61, ...],
  "output": [null, null, null, null, null, null, 43.99, 44.16, ...]
}
```

Generated once with a small Node.js script wrapping the npm `technicalindicators` package; committed to the repo. Tests load these and assert parity within 1e-6.

## 3.8 Out of scope for Phase 3
- Strategy logic (Phase 4) — indicators only produce values, they do not say "buy" or "sell".
- Real-time UI chart rendering (Phase 5) — indicators just emit; UI consumes.
- Backtesting integration (Phase 7) — indicators are reusable, but backtest harness is later.

## Effort estimate
~5-7 days. Most time goes into parity tests with `technicalindicators`. The new indicators (OIDelta, FundingZ, CVD, LiquidationPulse) are simple math; getting them wired to the materializer and Oban is the operational work.

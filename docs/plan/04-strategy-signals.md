# Phase 4 — Counterflow Strategy & Signals

**Goal:** Combine Phase 3 indicators into composite-scored trade signals, dispatch to alert sinks, persist for backtesting and review.

**Exit criteria:**
- Live signal feed populates against streaming data with non-trivial signal rate (target: 1-10 signals/hour across 30-symbol watchlist).
- Replay of last 30d through the strategy generates ≥ 100 signals with no duplicate IDs.
- Old-bot parity mode: with composite_threshold=0.0 and TF-only weighting, regenerates the same alerts the old bot would have fired on the same candles (validation against captured fixtures).
- Telegram and desktop sinks deliver test signals in dev environment.

## 4.1 Signal struct

```elixir
defmodule Counterflow.Signal do
  @type side :: :long | :short
  @type t :: %__MODULE__{
    id: binary(),                       # `<symbol>:<interval>:<time_unix>:<side>`
    symbol: String.t(),
    interval: String.t(),               # e.g. "5m" — bar that produced the signal
    side: side(),
    score: float(),                     # 0.0 .. 1.0
    components: %{atom() => float()},   # contribution of each indicator, signed
    price: Decimal.t(),
    leverage_suggested: 1..10,
    sl: Decimal.t(),                    # stop-loss price
    tp1: Decimal.t(),                   # first take-profit (typically 1R)
    tp2: Decimal.t(),                   # second take-profit (typically 2R)
    ttl_minutes: pos_integer(),         # how long this signal is actionable
    notes: [String.t()],                # human-readable explanation lines
    generated_at: DateTime.t()
  }
  defstruct [:id, :symbol, :interval, :side, :score, :components, :price,
             :leverage_suggested, :sl, :tp1, :tp2, :ttl_minutes, :notes, :generated_at]
end
```

Persisted to `signals` hypertable:
```sql
CREATE TABLE signals (
  id           TEXT NOT NULL,
  symbol       TEXT NOT NULL,
  interval     TEXT NOT NULL,
  side         TEXT NOT NULL,
  score        NUMERIC(6, 4) NOT NULL,
  components   JSONB NOT NULL,
  price        NUMERIC(24, 12) NOT NULL,
  leverage     INTEGER NOT NULL,
  sl           NUMERIC(24, 12),
  tp1          NUMERIC(24, 12),
  tp2          NUMERIC(24, 12),
  ttl_minutes  INTEGER NOT NULL,
  notes        TEXT[],
  generated_at TIMESTAMPTZ NOT NULL,
  outcome      JSONB,                    -- filled in async after TTL: {hit_tp1, hit_tp2, hit_sl, expired, peak_R, trough_R}
  PRIMARY KEY (id, generated_at)
);
SELECT create_hypertable('signals', 'generated_at', chunk_time_interval => INTERVAL '30 days');
CREATE INDEX signals_symbol_time ON signals (symbol, generated_at DESC);
```

## 4.2 Composite scorer

`Counterflow.Strategy.Counterflow` (yes, the strategy module is named the same as the app — module is the strategy implementation, app is the platform).

```elixir
defmodule Counterflow.Strategy.Counterflow do
  @behaviour Counterflow.Strategy

  @default_weights %{
    tf_spike:        0.25,
    oi_divergence:   0.20,
    funding_z:       0.15,
    liquidation:     0.15,
    cvd_divergence:  0.15,
    lsr_extreme:     0.10
  }

  @default_threshold 0.55

  def evaluate(%StrategyInput{} = input, opts \\ []) do
    weights = Keyword.get(opts, :weights, @default_weights)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    case directional_bias(input) do
      :neutral -> :no_signal
      side ->
        components = %{
          tf_spike:       tf_component(input, side),
          oi_divergence:  oi_component(input, side),
          funding_z:      funding_component(input, side),
          liquidation:    liquidation_component(input, side),
          cvd_divergence: cvd_component(input, side),
          lsr_extreme:    lsr_component(input, side)
        }
        score = weighted_sum(components, weights)
        if score >= threshold and trend_filter_ok?(input, side) do
          {:signal, build_signal(input, side, score, components)}
        else
          :no_signal
        end
    end
  end
end
```

`directional_bias/1` first cuts: any of these alone selects a side, but the score still has to clear the threshold:
- TF spike + price closing in candle direction → side = candle direction (this is the old-bot behavior)
- Funding |z| > 2 in either direction → contra side (long if z very negative, short if z very positive)
- Liquidation pulse > 90th percentile + dominant_side = `:longs_blown` → side = long (catching the v-bottom after capitulation, contra-trend); reverse for shorts_blown.

If two heuristics disagree → `:neutral`, no signal.

Each `*_component/2` function returns a value in **[-1.0, 1.0]** signed *toward the side under consideration*: positive contribution if the indicator supports the side, negative if it contradicts.

Example: `tf_component(input, :long)`:
```elixir
defp tf_component(%{tf: %{value: level, candle: candle}}, :long) do
  cond do
    candle.close > candle.open and level >= 3 -> level / 6  # 6 is max level
    candle.close > candle.open and level == 2 -> 0.3
    candle.close < candle.open                 -> -level / 6  # contrary candle
    true                                       -> 0.0
  end
end
```

## 4.3 Trend filter (hard mask, not score)

After scoring crosses threshold, require trend alignment via the configured `profile` (kept from old bot, but now per-symbol-overridable). The composite scorer makes the *probabilistic* call; the trend filter ensures we don't fade an obviously strong move (the smart-money setup needs a trend that retail is leaning into).

```elixir
defp trend_filter_ok?(%{ema7: e7, ema25: e25, ema99: e99, candle: c}, side) do
  case side do
    :long  -> Decimal.gt?(c.close, e7) and (e7 >= e25 or :loose)   # configurable
    :short -> Decimal.lt?(c.close, e7) and (e7 <= e25 or :loose)
  end
end
```

Three `profile` values map to filter strictness:
- `1` (strict): full stack, e7 > e25 > e99 for long (or all reversed)
- `2` (default): close vs e7 vs e25
- `3` (loose): close vs e7 only

## 4.4 Stop-loss / take-profit calculation

Per-signal SL is computed structurally (not arbitrary %):
- **Long signal SL**: low of the most recent N=3 closed candles, minus a 0.1% buffer. (For shorts: high of last 3 + 0.1%.)
- **TP1** = price + 1R, where `R = price - SL` (in long terms).
- **TP2** = price + 2R.
- **TTL minutes** = `2 × interval_minutes × 12` (e.g. 5m signal → 120 min validity), bounded [60, 720].

`leverage_suggested` is conservatively derived from R as a fraction of price:
```elixir
defp suggest_leverage(price, sl) do
  r_pct = Decimal.div(Decimal.abs(Decimal.sub(price, sl)), price) |> Decimal.to_float()
  cond do
    r_pct < 0.005 -> 10   # tight stop, can size up
    r_pct < 0.01  -> 5
    r_pct < 0.02  -> 3
    true          -> 2
  end
end
```

But the broker layer (Phase 6+) caps actual deployed leverage at **5× until user explicitly raises**, regardless of suggestion.

## 4.5 Dedup / cool-down

Per `(symbol, side)` cool-down: 15 min default, configurable. Implemented in `Counterflow.Strategy.Cooldown` (ETS table, `{symbol, side} -> last_emit_at`):

```elixir
def maybe_emit(signal) do
  key = {signal.symbol, signal.side}
  case :ets.lookup(:cooldown, key) do
    [{^key, last_at}] ->
      if DateTime.diff(signal.generated_at, last_at, :second) < cooldown_seconds(signal),
         do: :suppressed, else: do_emit(signal)
    [] -> do_emit(signal)
  end
end
```

Cool-down scales with interval: 5m signal → 15 min cooldown; 1h signal → 60 min; 1m signal → 5 min.

## 4.6 Lifecycle

```
[indicator update on candle close]
        │
        ▼
Counterflow.Strategy.Pipeline.evaluate(symbol, interval)
        │
        ├── load latest indicator values from indicator_values
        ├── load last N candles, OI series, LSR series, funding series, recent liqs, current depth
        ├── build %StrategyInput{}
        ├── call Counterflow.Strategy.Counterflow.evaluate/2
        │
        ├── if {:signal, sig}:
        │       ├── Cooldown.maybe_emit(sig)
        │       ├── Repo.insert(sig)
        │       ├── Phoenix.PubSub.broadcast("signals:new", {:signal, sig})
        │       ├── Phoenix.PubSub.broadcast("signals:#{sig.symbol}", {:signal, sig})
        │       └── Counterflow.Alerts.dispatch(sig)
        │
        └── schedule outcome evaluation Oban job at generated_at + ttl_minutes
```

Outcome job (`Counterflow.Strategy.OutcomeEvaluator`) fetches all candles between `generated_at` and `generated_at + ttl_minutes`, determines if SL or TP hit first (intra-candle high/low), records `outcome` JSONB on the signal row. This data feeds Phase 7 backtest validation and Phase 9 ML training.

## 4.7 Alert dispatcher

```elixir
defmodule Counterflow.Alerts do
  @sinks Application.compile_env(:counterflow, :alert_sinks, [Counterflow.Alerts.LiveView])

  def dispatch(signal) do
    Enum.each(@sinks, fn sink ->
      Task.Supervisor.start_child(Counterflow.Alerts.TaskSup, fn -> sink.send(signal) end)
    end)
  end
end
```

Sink implementations:
- `Counterflow.Alerts.LiveView` — no-op (LiveView already subscribes via PubSub).
- `Counterflow.Alerts.Desktop` — uses a small Elixir port to `notify-send` (linux) / `osascript` (mac).
- `Counterflow.Alerts.Telegram` — bot API, configurable chat id per user, message format includes inline button to open `/symbol/:symbol` in the dashboard.
- `Counterflow.Alerts.Discord` — webhook POST.

Message template:
```
🔻 SHORT BTCUSDT @ 67,400  (5m, score 0.71)
SL 67,820   TP1 66,560   TP2 65,720
Components: tf=+0.83 oi=+0.62 funding=+1.20σ liq_pulse=89%ile
Notes: longs_trapped (OI ↑3.1%, price -1.2%) | longs_blown 12m
```

## 4.8 Old-bot parity mode

For validation in Phase 7, expose a `:legacy_bot` strategy preset:
```elixir
@legacy_weights %{tf_spike: 1.0, oi_divergence: 0.0, funding_z: 0.0, liquidation: 0.0, cvd_divergence: 0.0, lsr_extreme: 0.0}
@legacy_threshold 0.5     # picked so TF level ≥ 3 fires
```

With these settings, plus the trend filter set to old-bot `profile=2`, the strategy should fire the same alerts the old bot did on the same input. Build a fixture: capture `notification.log` output from the old bot replayed against the same candle history, run our pipeline against the same data, compare. Tolerate timing differences (old bot fired on first candle close, we may persist a tick later) but require ≥ 95% alert match.

This is the *proof* that we faithfully ported the algorithm before adding our own components.

## 4.9 Configuration

Per-symbol strategy config in `symbol_strategy_config` table:
```sql
CREATE TABLE symbol_strategy_config (
  symbol            TEXT PRIMARY KEY,
  enabled           BOOLEAN DEFAULT true,
  interval          TEXT DEFAULT '5m',
  weights           JSONB,                      -- override defaults
  threshold         NUMERIC(4, 3),
  trend_profile     INTEGER DEFAULT 2,
  cooldown_minutes  INTEGER,
  max_leverage      INTEGER DEFAULT 5,
  enable_alerts     BOOLEAN DEFAULT true,
  enable_paper      BOOLEAN DEFAULT false,
  enable_live       BOOLEAN DEFAULT false       -- Phase 8
);
```

Defaults loaded from `config/runtime.exs`; per-symbol overrides via `/settings` UI (Phase 5).

## 4.10 Out of scope for Phase 4
- Order execution (Phases 6-8). Strategy emits signals; broker decides whether to act.
- Strategy parameter optimization (Phase 7 walk-forward).
- Multi-strategy ensemble (Phase 9).

## Effort estimate
~5-7 days. Most risk: the directional_bias logic — it's easy to write code that always finds *some* signal (over-trading) or never finds one (under-trading). Calibration against historical replay (Phase 7) is essential before this is trusted in paper trading.

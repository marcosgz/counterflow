# Phase 7 — Backtesting & Walk-Forward Validation

**Goal:** Replay historical data through the *same* indicator + strategy + paper-broker pipeline, with deterministic results, parameter sweeps, and walk-forward validation.

**Exit criteria:**
- Full backtest of 90 days × 30 symbols × 5m interval completes in < 30 min on dev hardware.
- Identical results across two consecutive runs of the same configuration (deterministic).
- Walk-forward report shows out-of-sample performance with equity curve, Sharpe, profit factor, max drawdown.
- Parameter sweep grid runs via Oban without rate-limit issues (no live Binance calls during backtest).
- LiveView `/backtest` page launches and compares runs.

## 7.1 Core principle: same code path

The strategy code that ran live in Phase 4 must run unchanged in backtest mode. The only differences:

1. **Time source** — replace `DateTime.utc_now()` with a `Counterflow.Clock` behaviour:
```elixir
defmodule Counterflow.Clock do
  @callback now() :: DateTime.t()
end
defmodule Counterflow.Clock.Real do
  @behaviour Counterflow.Clock
  def now, do: DateTime.utc_now()
end
defmodule Counterflow.Clock.Replay do
  @behaviour Counterflow.Clock
  def now, do: Process.get(:replay_clock) || DateTime.utc_now()
end
```
All app code calls `Counterflow.Clock.now/0` (alias to `Application.get_env(:counterflow, :clock).now/0`). In replay mode, the engine sets `Process.put(:replay_clock, ts)` before each event.

2. **Data source** — instead of subscribing to live PubSub, the replay engine reads hypertable rows in time order and synthesizes the events the live system would have seen.

3. **Broker** — uses `Counterflow.Broker.Paper` with deterministic slippage (random seeds fixed) and a synthetic aggTrade stream.

## 7.2 Replay engine

`Counterflow.Backtest.Replayer`:

```elixir
def run(opts) do
  symbol     = Keyword.fetch!(opts, :symbol)
  interval   = Keyword.fetch!(opts, :interval)
  from       = Keyword.fetch!(opts, :from)
  to         = Keyword.fetch!(opts, :to)
  strategy_opts = Keyword.get(opts, :strategy_opts, [])
  account_id = "bt-#{:rand.uniform(1_000_000)}"

  setup_account(account_id, opts)

  # Stream events in chronological order across all data sources.
  events = merge_streams([
    candle_stream(symbol, interval, from, to),
    oi_stream(symbol, from, to),
    lsr_stream(symbol, from, to),
    funding_stream(symbol, from, to),
    liquidation_stream(symbol, from, to),
    aggtrade_stream(symbol, from, to)        # for fill simulation
  ])

  Enum.each(events, fn ev ->
    Process.put(:replay_clock, ev.time)
    handle_event(ev, account_id, strategy_opts)
  end)

  finalize_report(account_id, opts)
end
```

`merge_streams/1` is a k-way merge over Postgrex streams (no full materialization in memory). Each event is `{type, time, payload}`.

`handle_event/3`:
- Candle close → invoke indicators, then strategy, then bridge to broker (which may place orders).
- AggTrade → broker matcher checks open orders for fills.
- OI/LSR/Funding/Liquidation → update materialized indicator series.

## 7.3 Performance

Targets: 90 days × 30 symbols × 5m candles ≈ 800k candle events + ~50× more aggTrade events. With single-process execution at ~10k events/s, that's ~75 min. To hit the < 30 min target, parallelize per-symbol (each symbol is independent in backtest):

```elixir
def run_multi(symbols, opts) do
  Task.async_stream(symbols, &run([{:symbol, &1} | opts]),
                    max_concurrency: System.schedulers_online(),
                    ordered: false, timeout: :infinity)
  |> Enum.map(fn {:ok, report} -> report end)
end
```

Postgrex pool sized accordingly (16+ connections). Use `Repo.transaction(fn -> Repo.stream(...) end)` for streamed reads.

## 7.4 Data preparation

Backtest depends on Phase 2 data being already backfilled. The Mix task `mix counterflow.backtest_prepare --symbols ALL --days 365` ensures:
- Klines at 1m, 5m, 1h for the period.
- OI history (5m granularity).
- LSR history (5m granularity, all 3 sources).
- Funding rates (every 8h since listing).
- Liquidations (full firehose since available — only ~30d retention by default; user may need to ingest live for longer to have backtest depth).
- AggTrades: large. We use a sampled approach: store ~5% of aggTrades for fill simulation, sufficient for slippage realism without 10× DB cost.

If aggTrades aren't available for the requested window, the engine falls back to **synthetic aggTrades** generated from the candle (uniform distribution across HLC range), with a flag in the run report (`fill_method: :synthetic`).

## 7.5 Determinism

All sources of nondeterminism eliminated:
- Random slippage uses a seeded RNG keyed on `(account_id, order_id)`.
- Iteration order is strictly chronological; ties broken by `(event_type_priority, source_id)`.
- No `DateTime.utc_now()` in app code (enforced by Credo rule).
- Float arithmetic is platform-stable in EMA/RSI (avoid `:rand`).

Two consecutive runs of the same `Backtest.Run.config` produce byte-identical `paper_fills` and `paper_positions`. The test harness asserts this.

## 7.6 Walk-forward validation

```elixir
defmodule Counterflow.Backtest.WalkForward do
  def run(opts) do
    train_weeks = Keyword.get(opts, :train_weeks, 12)
    test_weeks  = Keyword.get(opts, :test_weeks, 1)

    windows = build_windows(opts.from, opts.to, train_weeks, test_weeks)

    Enum.map(windows, fn {train_range, test_range} ->
      # 1. Optimize weights on train_range
      best_weights = ParameterSweep.optimize(opts.symbol, train_range, opts.weight_grid)

      # 2. Evaluate on test_range with frozen weights
      report = Replayer.run(symbol: opts.symbol, from: test_range.from, to: test_range.to,
                            strategy_opts: [weights: best_weights])

      %{train: train_range, test: test_range, weights: best_weights, report: report}
    end)
  end
end
```

Aggregate report: per-window OOS metrics + concatenated equity curve.

## 7.7 Parameter sweep

`Counterflow.Backtest.ParameterSweep`:

Grid example:
```elixir
%{
  threshold: [0.45, 0.50, 0.55, 0.60, 0.65],
  cooldown_minutes: [10, 15, 30, 60],
  weights: [
    %{tf_spike: 0.25, oi_divergence: 0.20, ...},   # default
    %{tf_spike: 0.40, oi_divergence: 0.15, ...},   # tf-heavy
    %{tf_spike: 0.10, oi_divergence: 0.30, ...}    # oi-heavy
  ]
}
```

Cartesian product of the grid → N runs, each persisted as a row in `backtest_runs`:

```sql
CREATE TABLE backtest_runs (
  id              UUID PRIMARY KEY,
  config          JSONB NOT NULL,                  -- full Replayer opts
  status          TEXT NOT NULL,                   -- queued | running | done | failed
  started_at      TIMESTAMPTZ,
  finished_at     TIMESTAMPTZ,
  metrics         JSONB,                            -- aggregate metrics
  notes           TEXT
);
```

Each run is an Oban job in queue `:backtest` (concurrency = `System.schedulers_online()`).

Selection criterion (default): rank by **profit factor** with **Sharpe ≥ 1.0** and **max drawdown ≤ 15%** as constraints. Configurable.

## 7.8 Metrics

Per backtest run:
- Total return %
- Annualized return %
- Sharpe ratio (daily, risk-free=0)
- Sortino ratio
- Max drawdown %
- Profit factor (gross profit / gross loss)
- Win rate
- Average R-multiple (avg trade PnL / avg trade risk)
- MAE/MFE distribution (Maximum Adverse Excursion / Maximum Favorable Excursion)
- Signal-to-noise: % of signals that touched TP1 before SL
- Kelly fraction (suggested optimal sizing)
- Trades per day
- Avg trade duration
- Per-symbol breakdown
- Per-side breakdown (long vs short)
- Per-component contribution analysis (which indicator drove the most profitable signals)

All persisted to `metrics` JSONB so future runs can be compared without recomputation.

## 7.9 LiveView `/backtest`

**Launch panel**: form for symbol(s), interval, date range, strategy preset (`:default | :legacy_bot | :custom`), parameter grid (or single config). Submit → enqueues Oban job(s).

**Run list**: paginated table of past runs, status, date submitted, key metrics.

**Run detail page**: equity curve, trade list, fill markers on candle chart, metrics breakdown, click-through to per-signal detail.

**Compare page**: pick 2-4 runs, side-by-side equity curves, metric deltas.

## 7.10 Old-bot regression test

Special test mode: replay the last 6 months with `strategy_opts: [preset: :legacy_bot]`. Compare the generated signals to the captured `notification.log` from the original Node.js bot run on the same period (we extract these from the bot if the user has logs, or run the bot once headless to capture).

Acceptance: ≥ 95% match on (symbol, time, side) tuples. Differences attributable to indicator boundary effects (we may use slightly different candle availability) are tolerated. This proves we faithfully ported the algorithm.

## 7.11 Out of scope for Phase 7
- Real-money out-of-sample testing (Phase 8).
- ML-based weight learning (Phase 9 — uses Phase 7 outcomes as labels).
- Distributed multi-machine backtesting (single-machine is plenty for this scale).

## Effort estimate
~7-10 days. The Clock + replay scaffolding is a refactor of existing code; the metric calculations and walk-forward orchestration are net-new. Non-trivial debugging time for non-determinism leaks (process state, ETS, etc.).

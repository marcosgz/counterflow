# Counterflow — Overview

## Mission
Detect "smart money" footprints (large concentrated activity that pulls price up/down to harvest leveraged liquidations on the opposite side) on Binance USDT-M Futures, deliver real-time signals through a Phoenix LiveView UI, and execute counter-trend leveraged trades — first via paper trading, then Binance Testnet, then live with hard risk limits.

## Why "Counterflow"
- Counter-trend bias: smart money fades retail crowding. The strategy goes *against* the dominant flow.
- Single, unambiguous, no trademark conflict, .com / .io likely available (verify before launch).

## Strategic angle vs the old bot
The 4-year-old bot fired on three signals:
1. **Trend filter** (price vs EMA 7/25/99 stack)
2. **Trade Force (TF) spike** (trade-count spike ≥ N× the rolling avg)
3. **LSR EMA crossover** (long/short ratio rolling over)

It worked because in 2021–2022, retail-LSR data still leaked the smart-money fade. In 2026 the edge has decayed (everyone reads LSR now), so we keep the TF spike (still useful — bots slice orders into many small fills, so trade-count spikes detect this even when volume looks normal) and add modern signals:

| Signal | Source | Why it matters |
|---|---|---|
| **Trade Force (TF)** | aggregated kline trades count | Catches order-slicing by execution algos |
| **OI Δ + price divergence** | `/futures/data/openInterestHist` | OI ↑ + price flat = positions stacking (squeeze setup) |
| **Funding extremes** | `/fapi/v1/premiumIndex` | Funding > +0.05% / 8h = longs pay heavily, primed for flush |
| **Liquidation clusters** | `!forceOrder@arr` ws | Cascading liquidations = smart-money exit liquidity |
| **CVD divergence** | aggTrades stream, taker side | Price up but CVD flat = absorption by passive sellers |
| **LSR + RSI(LSR)** | `/futures/data/globalLongShortAccountRatio` | Kept from old bot, weighted lower |
| **Order-book imbalance** | `<symbol>@depth` partial book | Spoofing / iceberg detection (advanced phase) |

A signal is scored 0-1; trades only fire on **composite scores ≥ threshold**, not single-indicator triggers. This dramatically reduces false positives compared to the old bot's AND-gate.

## Architecture (high-level)
```
                 ┌────────── Binance Futures REST (REST poller GenServer per endpoint) ──┐
                 ├────────── Binance Futures WS (kline/aggTrade/forceOrder/depth) ───────┤
                                                │
                                                ▼
                              Counterflow.Ingest (per-symbol GenServer registry)
                                                │
                                                ▼
                              TimescaleDB (community)  ← hypertables for candles, oi, lsr,
                                                                     funding, liquidations, signals
                                                │
                                                ▼
                              Counterflow.Indicators (pure functions, called per closed candle)
                                                │
                                                ▼
                              Counterflow.Strategy (composite scorer → Signal struct)
                                                │
                                  ┌─────────────┼──────────────┐
                                  ▼             ▼              ▼
                         Phoenix.PubSub    Paper Broker    Live Broker (gated)
                                  │             │              │
                                  ▼             ▼              ▼
                          LiveView UI    Simulated fills    Binance API
                                                                (testnet → real)
```

Why Elixir fits: per-symbol supervised GenServers map naturally to per-symbol ingestion + state, BEAM handles 400+ concurrent ws subscriptions trivially, fault isolation per symbol, hot reload during strategy iteration, LiveView gives real-time UI without a separate frontend stack.

## Universe strategy
- **All ~400 USDT-M perps** are tracked at low resolution (1h candles + 5m OI + 5m LSR).
- **Watchlist** (initial cap 30) gets full-resolution: 1m/5m/1h/4h candles, aggTrades, liquidations, depth.
- **Promotion algorithm** (Phase 2): a symbol is auto-promoted when *any* of:
  - 24h OI growth > 20% AND price move < 5% (positions stacking without price action)
  - Funding rate |z-score| > 2.5 across 30-day window
  - Liquidation volume in last 1h > 5× 30-day avg
  - Manual pin by user
- **Demotion**: drop after 24h with no qualifying activity, unless pinned.

## Phasing
The plan is split into 9 phase docs. Each phase is independently shippable and gated by an explicit "exit criteria" before moving on.

| Phase | File | Outcome |
|---|---|---|
| 1 | `01-foundation.md` | Phoenix project, Binance REST/WS clients, TimescaleDB up, single-symbol kline pipeline working |
| 2 | `02-data-pipeline.md` | Full data ingestion: klines, OI, LSR, funding, liquidations, aggTrades. Watchlist auto-promotion. |
| 3 | `03-indicators-engine.md` | Indicator library (PF, VF, TF, EMAs, OI delta, CVD, funding-z, RSI(LSR)). Backfill on historical data. |
| 4 | `04-strategy-signals.md` | Counterflow strategy: composite scorer, signal struct, alerts, dispatch via PubSub. Replicates + improves old bot. |
| 5 | `05-liveview-ui.md` | LiveView dashboard: watchlist, embedded TradingView chart, live signals feed, OI/LSR/funding panels. |
| 6 | `06-paper-trading.md` | Paper broker: simulated orders, slippage model, fills from live tape, PnL + drawdown tracking. |
| 7 | `07-backtesting.md` | Historical replay engine, parameter sweep, performance metrics, walk-forward validation. |
| 8 | `08-live-execution.md` | Binance testnet integration → real account with kill-switches, position limits, daily loss caps. |
| 9 | `09-future-roadmap.md` | Spot trading, ML signal scoring, multi-exchange (Bybit/OKX), mobile alerts, copy-trading. |

## Tech stack (pinned)
- Elixir 1.18+ / Erlang 27+
- Phoenix 1.7+ with LiveView 1.0+
- Ecto 3.12+
- PostgreSQL 16 + **TimescaleDB community** (Apache 2 license, no enterprise features)
- Tailwind 4 + DaisyUI for fast dashboard styling
- TradingView Charting Library (free embedded widget) — for charts only
- `WebSockex` for Binance WS, `Req` for REST, `Finch` HTTP pool
- `Oban` for scheduled jobs (OI history backfill, daily report, etc.)
- `Phoenix.PubSub` (default Registry adapter; no Redis needed)
- Telemetry → Prometheus → Grafana for ops (Phase 8)

## Constraints / non-goals
- **No mocking strategy code in tests.** Strategy correctness is verified through historical replay (Phase 7), not unit-test mocks.
- **No live orders before Phase 8 exit criteria.** Paper trading must show ≥ 60% win rate or ≥ 1.5 profit factor across ≥ 200 signals on out-of-sample data first.
- **No Pine Script porting.** TradingView indicator code is paywalled; we reimplement equivalent logic from public formulas only.
- **TimescaleDB community only**, no compression/continuous-aggregates enterprise features.
- **No supply-chain risk shortcuts**: pin all deps, lockfile committed, dependabot enabled before live trading.

## Open questions (capture as we learn)
- Capital scale → execution model (Phase 8). User has not decided yet; we'll plan for $1k–$10k initial deployment unless told otherwise.
- Hosting: target a single VPS (Hetzner CX32 ~€7/mo) for Phase 1–6, evaluate move to dedicated for live trading.
- Webhook alerts (Telegram / Discord) — confirm preference in Phase 4.

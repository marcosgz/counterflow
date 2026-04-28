# Counterflow — Onboarding

A guided tour of the project: what's built, how to run it, and how to verify it.

## What is Counterflow

A real-time crypto smart-money detector for **Binance USDT-M Futures**, written in Elixir/Phoenix LiveView. It ingests klines, open interest, long/short ratio, funding rates, and the liquidation firehose into TimescaleDB, runs a composite-weighted strategy ("Counterflow") that fades retail crowd positioning into smart-money liquidation events, and dispatches signals through PubSub. A paper broker provides full PnL tracking; a deterministic backtester replays history through the same strategy code; a fail-closed live broker stub is wired but disabled until an explicit Phase 8b activation step is taken.

Strategic thesis (see `docs/plan/00-overview.md`): keep the legacy bot's **Trade Force** trade-count spike (still useful — execution algos slice into many small fills) and combine it with **OI delta + price divergence**, **funding-rate z-score**, **liquidation-cluster percentile**, **CVD divergence** (placeholder), and a down-weighted **LSR extreme**. Composite scoring replaces the legacy hard-AND gate that under-fires in changing regimes.

## Phase status

| Phase | Status | Doc |
|---|---|---|
| 1. Foundation | ✓ shipped | `docs/plan/01-foundation.md` |
| 2. Data Pipeline | ✓ shipped (full ingest, manual watchlist; auto-promotion still TBD) | `docs/plan/02-data-pipeline.md` |
| 3. Indicators Engine | ✓ shipped | `docs/plan/03-indicators-engine.md` |
| 4. Strategy & Signals | ✓ shipped | `docs/plan/04-strategy-signals.md` |
| 5. LiveView UI | ✓ shipped (text panels; TV widget + Chart.js deferred) | `docs/plan/05-liveview-ui.md` |
| 6. Paper Trading | ✓ shipped (MARKET fills + slippage + fees + PnL) | `docs/plan/06-paper-trading.md` |
| 7. Backtesting | ✓ shipped (replayer + metrics; walk-forward TBD) | `docs/plan/07-backtesting.md` |
| 8. Live Execution | ✓ stub shipped (gates + kill switch active; HMAC + actual REST submission deliberately not wired — Phase 8b activation step) | `docs/plan/08-live-execution.md` |
| 9. Future roadmap | reference only | `docs/plan/09-future-roadmap.md` |

## Prerequisites

- **Elixir** 1.18+ / Erlang 27+ (project uses 1.19.5 / OTP 28)
- **Docker** + docker-compose for TimescaleDB
- **PostgreSQL client** (`psql`) — optional, for poking at the DB

## First-time setup

```bash
# 1. Bring up TimescaleDB (port 5433 to avoid conflicts)
cd /home/marcos/claude-workspace/crypto
docker-compose -f compose.dev.yml up -d

# 2. Install Elixir deps + create + migrate the DB
cd counterflow
mix deps.get
mix ecto.create
mix ecto.migrate

# 3. (Optional) compile + run tests
mix compile
mix test

# 4. Boot the dev server
mix phx.server
```

Then open <http://localhost:4000>. You should see the watchlist and live data within ~30 seconds.

## Project layout

```
crypto/
├── compose.dev.yml              # TimescaleDB on port 5433
├── docs/
│   ├── ONBOARDING.md            # this file
│   └── plan/                    # per-phase implementation contracts
└── counterflow/                 # the Phoenix application
    ├── lib/
    │   ├── counterflow/         # business domain (no Phoenix deps)
    │   │   ├── application.ex   # supervision tree
    │   │   ├── binance/         # REST + WS clients
    │   │   ├── ingest/          # supervisors, pollers, symbol workers
    │   │   ├── market/          # Ecto schemas: Candle, OpenInterest, etc.
    │   │   ├── indicators/      # pure-function indicator library
    │   │   ├── strategy/        # Counterflow strategy + dispatcher + cooldown
    │   │   ├── broker/          # behaviour + Paper + Live (stub) impls
    │   │   ├── backtest/        # Replayer + Metrics
    │   │   ├── risk/            # KillSwitch + Gates
    │   │   ├── watchlist/       # Manager (dynamic per-symbol supervision)
    │   │   ├── repo.ex
    │   │   ├── clock.ex         # process-dict clock (live ↔ replay)
    │   │   └── watchlist.ex     # public watchlist API
    │   └── counterflow_web/
    │       ├── live/
    │       │   ├── overview_live.ex
    │       │   ├── watchlist_live.ex
    │       │   ├── signals_live.ex
    │       │   └── symbol_live.ex
    │       └── router.ex
    ├── priv/repo/migrations/    # 5 migrations: candles, market data, signals,
    │                            # paper trading, live execution
    └── test/                    # 51 tests, 0 failures
```

## How the data flows

```
Binance REST/WS ──► Ingest.Pollers + WS.Kline + WS.Liquidations
                          │
                          ▼ (persists to TimescaleDB hypertables)
              candles, open_interest, long_short_ratio,
              funding_rates, liquidations, cvd_bars
                          │
                          ▼ (broadcasts via Phoenix.PubSub)
                  candles:<sym>:<int>, signals:new,
                  liquidations:firehose, ...
                          │
                  ┌───────┴────────┐
                  ▼                ▼
            LiveView pages    Strategy.Pipeline (TBD wiring)
                                     │
                                     ▼
                              Strategy.Counterflow.evaluate
                                     │
                                     ▼ {:signal, sig}
                              Strategy.Dispatcher
                                     │
                  ┌──────────────────┼────────────┐
                  ▼                  ▼            ▼
              signals table    PubSub feed    Alert sinks
                                                  │
                                       ┌──────────┴────────┐
                                       ▼                   ▼
                                  Paper Broker         Live Broker
                                                  (gated, fail-closed)
```

## Verification: prove every phase works

After `mix phx.server` is running, in another terminal:

```bash
# Phase 1+2 — ingestion
docker exec crypto-db-1 psql -U postgres -d counterflow_dev -c "
SELECT 'candles' AS t, COUNT(*) FROM candles
UNION ALL SELECT 'oi', COUNT(*) FROM open_interest
UNION ALL SELECT 'lsr', COUNT(*) FROM long_short_ratio
UNION ALL SELECT 'funding', COUNT(*) FROM funding_rates
UNION ALL SELECT 'liquidations', COUNT(*) FROM liquidations;"

# Phase 5 — UI routes return 200
for p in / /watchlist /signals /symbol/BTCUSDT; do
  echo "$p -> $(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:4000$p)"
done

# Phase 3+4+6+7+8 — full test suite
cd counterflow && mix test
```

Expected: candles ≥ 1440 (one per minute), funding ≈ 1440 (all symbols), liquidations grows with market activity, all routes 200, tests 51/0.

## Common workflows

### Add a new symbol to the watchlist

In the `/watchlist` UI, type the symbol (e.g. `SOLUSDT`) and click Add. This:
- Inserts into the `watchlist` table
- Starts a `SymbolWorker` + `WS.Kline` for each configured interval (`1m`, `5m`)
- Triggers a REST backfill of the last 720 candles per interval
- Begins live persisting closed candles + broadcasting via PubSub

### Run a paper trade by hand

```elixir
iex -S mix phx.server

iex> alias Counterflow.Broker.Paper
iex> Paper.ensure_account("me", Decimal.new(10_000))
iex> Paper.place_order("me", %{
  symbol: "BTCUSDT",
  side: "BUY",
  type: "MARKET",
  qty: Decimal.new("0.01"),
  reference_price: Decimal.new("67500")
})
iex> Paper.balance("me")
iex> Paper.positions("me")
```

### Run a backtest

```elixir
iex> alias Counterflow.Backtest.Replayer
iex> from = ~U[2026-04-25 00:00:00.000000Z]
iex> to   = ~U[2026-04-28 00:00:00.000000Z]
iex> Replayer.run(symbol: "BTCUSDT", interval: "5m", from: from, to: to)
%{signals: [...], candles_processed: 864, duration_ms: ~700}
```

The replayer reuses the live indicator + strategy modules verbatim; results are deterministic given the same DB state.

### Engage / release the kill switch

```elixir
iex> Counterflow.Risk.KillSwitch.engage("manual test", "marcos")
iex> Counterflow.Risk.KillSwitch.engaged?()  # => true
iex> Counterflow.Risk.KillSwitch.release("marcos")
```

Or set `COUNTERFLOW_KILL=1` at boot.

## What is *not* yet wired

These are scoped out of the current build, but the surface area is in place. Tracked in the phase docs:

- aggTrade ws ingestion + `cvd_bars` materialization (Phase 2)
- Watchlist auto-promotion algorithm (Phase 2 doc has the SQL; needs scheduler hookup)
- A pipeline GenServer that subscribes to `candles:<sym>:<int>:closed` and invokes the strategy automatically (Phase 4 — currently `Strategy.Counterflow.evaluate/2` is callable but not yet auto-invoked)
- TradingView widget + Chart.js panels (Phase 5)
- Walk-forward + parameter sweep orchestration (Phase 7)
- Phase 8b live order REST submission (deliberate friction — see operational checklist in `docs/plan/08-live-execution.md`)

## Troubleshooting

**`mix ecto.create` fails with "could not connect to localhost:5432"** — the dev DB is on port **5433** to avoid conflicting with other Postgres on your machine. Verify the container is up: `docker ps | grep crypto-db-1`.

**WS reconnect loop** — Binance occasionally drops connections. The `WS.Kline` and `WS.Liquidations` workers reconnect with exponential backoff (1s → 60s cap). Check `[info]` lines in the server log.

**Pollers crashing with "unknown registry: Req.Finch"** — `Counterflow.Finch` isn't started. It's registered in `application.ex`; if you removed it, add it back before any HTTP-using child.

**`utc_datetime_usec expects microsecond precision`** — Binance returns unix-ms, Ecto's `:utc_datetime_usec` requires microsecond. Use the `ms_to_dt/1` helper (`DateTime.from_unix!(ms * 1000, :microsecond)`) — already done in all ingest paths.

**Tests fail with "module not found"** — run `mix deps.get` then `mix compile`. Some warnings ("pattern matching on 0.0") are stylistic and can be ignored.

## Key files to read first

If you want to understand the system in 30 minutes, read in this order:

1. `docs/plan/00-overview.md` — vision, signal table, phasing
2. `counterflow/lib/counterflow/application.ex` — supervision tree
3. `counterflow/lib/counterflow/ingest/supervisor.ex` — what runs at boot
4. `counterflow/lib/counterflow/binance/ws/kline.ex` — example ws pattern
5. `counterflow/lib/counterflow/strategy/counterflow.ex` — strategy logic
6. `counterflow/lib/counterflow/broker/paper.ex` — paper broker matching engine
7. `counterflow/lib/counterflow/risk/gates.ex` — what stands between a signal and a real order

## Useful commands cheat sheet

```bash
# DB
docker-compose -f compose.dev.yml up -d
docker-compose -f compose.dev.yml down
docker exec -it crypto-db-1 psql -U postgres -d counterflow_dev

# Phoenix
cd counterflow
mix phx.server                     # boot dev (port 4000)
iex -S mix phx.server              # boot dev with IEx attached
mix test                            # run full suite
mix test test/counterflow/         # only domain tests
mix compile --warnings-as-errors   # CI-grade compile
mix format                          # format all source
mix ecto.gen.migration NAME         # new migration
mix ecto.migrate
mix ecto.rollback

# Git (history is local-only — push when ready)
git log --oneline
```

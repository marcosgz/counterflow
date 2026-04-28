# Phase 1 — Foundation

**Goal:** Phoenix umbrella running, Binance clients functional, TimescaleDB persisting candles for one symbol (BTCUSDT, 1m), end-to-end smoke test green.

**Exit criteria:**
- `mix phx.server` boots a `/` LiveView showing live BTCUSDT 1m candle ticking.
- TimescaleDB hypertable `candles` has rows accumulating in real time.
- 24h continuous run with zero unhandled crashes (per-symbol supervisor restarts are fine).
- Reconnection works: kill the WS server-side (or use `tc` to drop), client recovers, no data gap > 30s.

## 1.1 Repository scaffold
```bash
mix archive.install hex phx_new
mix phx.new counterflow --live --database postgres --no-mailer --no-gettext
cd counterflow
git init && git add -A && git commit -m "initial phoenix scaffold"
```

Directory layout we'll grow into:
```
counterflow/
├── lib/
│   ├── counterflow/                  # business domain (no Phoenix deps)
│   │   ├── application.ex
│   │   ├── ingest/                   # data ingestion supervisors + workers
│   │   ├── binance/                  # binance REST + WS client
│   │   ├── repo/                     # Ecto repo + schemas
│   │   ├── indicators/               # pure indicator funs (Phase 3)
│   │   ├── strategy/                 # composite scoring (Phase 4)
│   │   └── broker/                   # paper / testnet / live (Phase 6+)
│   └── counterflow_web/              # phoenix + liveview
├── priv/repo/migrations/
├── config/
└── test/
```

## 1.2 Dependencies (`mix.exs`)
Pin minor versions, allow patch:
```elixir
{:phoenix, "~> 1.7.14"},
{:phoenix_live_view, "~> 1.0"},
{:phoenix_pubsub, "~> 2.1"},
{:ecto_sql, "~> 3.12"},
{:postgrex, "~> 0.19"},
{:timescaledb_ecto, "~> 0.4"},   # for hypertable migrations
{:websockex, "~> 0.4.3"},
{:req, "~> 0.5"},
{:finch, "~> 0.18"},
{:jason, "~> 1.4"},
{:decimal, "~> 2.1"},
{:oban, "~> 2.18"},
{:telemetry_metrics, "~> 1.0"},
{:telemetry_poller, "~> 1.1"},
```

## 1.3 TimescaleDB setup
Use the **community** image:
```yaml
# compose.dev.yml
services:
  db:
    image: timescale/timescaledb:latest-pg16
    environment:
      POSTGRES_PASSWORD: counterflow
      POSTGRES_DB: counterflow_dev
    ports: ["5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]
volumes: { pgdata: {} }
```

Migration `001_enable_timescaledb.exs`:
```elixir
def up, do: execute("CREATE EXTENSION IF NOT EXISTS timescaledb")
def down, do: execute("DROP EXTENSION timescaledb")
```

Migration `002_create_candles.exs`:
```elixir
create table(:candles, primary_key: false) do
  add :symbol, :string, null: false
  add :interval, :string, null: false   # "1m" | "5m" | "1h" | "4h" | "1d"
  add :time, :utc_datetime_usec, null: false
  add :open, :decimal, precision: 24, scale: 12, null: false
  add :high, :decimal, precision: 24, scale: 12, null: false
  add :low, :decimal, precision: 24, scale: 12, null: false
  add :close, :decimal, precision: 24, scale: 12, null: false
  add :volume, :decimal, precision: 28, scale: 8, null: false
  add :quote_volume, :decimal, precision: 28, scale: 8
  add :trades, :integer, null: false
  add :taker_buy_base, :decimal, precision: 28, scale: 8
  add :taker_buy_quote, :decimal, precision: 28, scale: 8
  add :closed, :boolean, null: false, default: false
end
create unique_index(:candles, [:symbol, :interval, :time])
execute("SELECT create_hypertable('candles', 'time', chunk_time_interval => INTERVAL '7 days')")
```

Use **`Decimal`** end-to-end for prices/sizes — never `float`. Binance returns strings; parse with `Decimal.new/1`.

## 1.4 Binance REST client (`Counterflow.Binance.Rest`)
Thin wrapper over `Req` with:
- Base URL by market: `https://fapi.binance.com` (USD-M futures), `https://api.binance.com` (spot, Phase 9), `https://testnet.binancefuture.com` (testnet, Phase 8).
- Rate-limit aware: read `X-MBX-USED-WEIGHT-1m` response header, back off when > 1100/1200 (default cap).
- Functions for Phase 1: `klines/3`, `exchange_info/0`, `server_time/0`. Other endpoints added in Phase 2.
- Returns `{:ok, struct}` / `{:error, %Counterflow.Binance.Error{}}` — error tagged with HTTP code, Binance error code, retry hint.

```elixir
defmodule Counterflow.Binance.Rest do
  @base "https://fapi.binance.com"

  def klines(symbol, interval, opts \\ []) do
    params = [symbol: symbol, interval: interval] ++ opts
    Req.get(@base <> "/fapi/v1/klines", params: params)
    |> handle()
  end
  # ...
end
```

## 1.5 Binance WS client (`Counterflow.Binance.WS.Kline`)
One `WebSockex` GenServer per (symbol, interval) — supervised under `DynamicSupervisor` keyed by `Counterflow.Ingest.Registry`.

Stream URL: `wss://fstream.binance.com/ws/{symbol_lower}@kline_{interval}`.

Behavior:
- On message → parse JSON → emit telemetry event `[:counterflow, :kline, :received]` → cast to per-symbol `Counterflow.Ingest.SymbolWorker`.
- Symbol worker dedups (Binance pushes the open candle every second; we only persist on `k.x == true`, but maintain in-memory current candle for LiveView push).
- Reconnect with exponential backoff (1s, 2s, 4s, ... cap 60s); on reconnect, do a REST gap-fill for any missed closed candles between last persisted `time` and `now`.
- Heartbeat: Binance ws pings every 3 min; we respond. If no message in 60s, force reconnect.

## 1.6 Ingest pipeline (single symbol for Phase 1)
```
Counterflow.Ingest.Supervisor
├── Counterflow.Ingest.Registry           (via Registry.start_link, :unique)
└── Counterflow.Ingest.SymbolSupervisor   (DynamicSupervisor)
    └── (one_for_one tree per symbol started on demand)
        ├── Counterflow.Binance.WS.Kline       (one per interval)
        └── Counterflow.Ingest.SymbolWorker    (state holder, persists, broadcasts)
```

`SymbolWorker` API:
```elixir
SymbolWorker.start({"BTCUSDT", ["1m"]})
SymbolWorker.snapshot("BTCUSDT")            # current state for LiveView mount
```

On closed candle:
1. Insert into `candles` (upsert on conflict).
2. Telemetry `[:counterflow, :candle, :closed]`.
3. `Phoenix.PubSub.broadcast("candles:BTCUSDT:1m", {:candle, candle})`.

## 1.7 Smoke-test LiveView
Single LiveView at `/` that:
- Subscribes to `candles:BTCUSDT:1m` on mount.
- Shows the last 50 candles in a simple HTML table (no chart yet — chart in Phase 5).
- Updates the last row on every WS tick, appends a new row on candle close.

This proves the full data path before we layer complexity.

## 1.8 Operational hygiene
- `mix format`, `credo --strict`, `dialyzer` — all green before merging.
- `.env`-style config via `config/runtime.exs` reading `BINANCE_API_KEY`/`SECRET` (Phase 8 needs these; Phase 1 uses public endpoints only).
- Log JSON in prod (`:logger_json`), pretty in dev.
- `mix test` baseline: smoke test of REST `klines` against a recorded fixture (use `Bypass` or `Req.Test` stubs — never hit live Binance in CI).

## 1.9 Out of scope for Phase 1
OI, LSR, funding, liquidations, multi-symbol, watchlist promotion, indicators, strategy, paper trading, charts → all later phases.

## Effort estimate
~3-5 days of focused work. The biggest time sinks are usually WS reconnection edge cases and getting the telemetry/supervision tree right — over-invest here, it pays back through every later phase.

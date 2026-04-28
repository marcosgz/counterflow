# Phase 2 — Data Pipeline & Watchlist

**Goal:** Stream the full Binance USDT-M Futures universe at low resolution + a 30-symbol watchlist at full resolution into TimescaleDB, with auto-promotion based on activity heuristics.

**Exit criteria:**
- 400+ symbols ingesting 1h klines + 5m OI/LSR/funding without rate-limit hits.
- 30 watchlist symbols ingesting 1m/5m/1h/4h klines + aggTrades + depth20.
- All symbols persisting liquidations from `!forceOrder@arr`.
- Watchlist auto-rebalances every 5 min based on activity.
- 7-day soak: zero `-1003` (rate-limit) errors, zero unhandled crashes, ≤ 5 GB DB growth.

## 2.1 Endpoint inventory

### REST (polled by `Counterflow.Ingest.RestPoller` GenServers, one per endpoint per symbol-tier)
| Endpoint | Path | Polling cadence | Used for |
|---|---|---|---|
| Klines | `/fapi/v1/klines` | Backfill only (WS for live) | Historical candles |
| Open Interest | `/fapi/v1/openInterest` | 30s (watchlist) / 5m (universe) | Latest OI per symbol |
| OI History | `/futures/data/openInterestHist` | 5m, period=5m | OI time series |
| Top L/S Account Ratio | `/futures/data/globalLongShortAccountRatio` | 5m, period=5m | Retail positioning |
| Top Trader L/S Position | `/futures/data/topLongShortPositionRatio` | 5m, period=5m | Top-trader positioning (often inverse to retail) |
| Top Trader L/S Account | `/futures/data/topLongShortAccountRatio` | 5m, period=5m | Confirm signal |
| Premium Index / Funding | `/fapi/v1/premiumIndex` | 30s (all symbols, single call returns all) | Funding rates + mark price |
| 24hr Ticker | `/fapi/v1/ticker/24hr` | 60s (single call, all symbols) | Volume rankings for promotion |
| Exchange Info | `/fapi/v1/exchangeInfo` | At boot + every 6h | Symbol filters (LOT_SIZE, PRICE_FILTER, MIN_NOTIONAL) |

### WebSocket streams (`Counterflow.Binance.WS.*` GenServers)
| Stream | URL | Scope |
|---|---|---|
| Kline | `<sym>@kline_<interval>` | watchlist × {1m, 5m, 1h, 4h} |
| Kline (low-res) | `<sym>@kline_1h` | universe (all ~400 symbols) |
| AggTrade | `<sym>@aggTrade` | watchlist only |
| Liquidations | `!forceOrder@arr` | single connection, all symbols |
| Partial book depth | `<sym>@depth20@100ms` | watchlist only |
| Mark price | `!markPrice@arr@1s` | single connection, all symbols (cheap) |

WS connection budget: Binance allows 200 streams per connection. We use **multi-stream connections** (`/stream?streams=...`) — one per logical group (e.g. one ws for all watchlist klines, one for all aggTrades, etc.). On watchlist promotion/demotion the connection is reconfigured: tear down + reconnect with new stream list (Binance does not support live re-subscription). Use a 1s debounce on watchlist changes to avoid reconnect thrash.

## 2.2 Hypertable schemas

```sql
-- klines already created in Phase 1; expand later if needed.

CREATE TABLE open_interest (
  symbol      TEXT NOT NULL,
  time        TIMESTAMPTZ NOT NULL,
  open_interest NUMERIC(28, 8) NOT NULL,    -- contracts
  oi_value    NUMERIC(28, 8),               -- USD value if available
  PRIMARY KEY (symbol, time)
);
SELECT create_hypertable('open_interest', 'time', chunk_time_interval => INTERVAL '7 days');

CREATE TABLE long_short_ratio (
  symbol       TEXT NOT NULL,
  time         TIMESTAMPTZ NOT NULL,
  source       TEXT NOT NULL,         -- 'global_account', 'top_position', 'top_account'
  long_ratio   NUMERIC(10, 6),
  short_ratio  NUMERIC(10, 6),
  ls_ratio     NUMERIC(10, 6) NOT NULL,
  PRIMARY KEY (symbol, source, time)
);
SELECT create_hypertable('long_short_ratio', 'time', chunk_time_interval => INTERVAL '7 days');

CREATE TABLE funding_rates (
  symbol         TEXT NOT NULL,
  time           TIMESTAMPTZ NOT NULL,
  funding_rate   NUMERIC(12, 8) NOT NULL,
  mark_price     NUMERIC(24, 12),
  index_price    NUMERIC(24, 12),
  PRIMARY KEY (symbol, time)
);
SELECT create_hypertable('funding_rates', 'time', chunk_time_interval => INTERVAL '30 days');

CREATE TABLE liquidations (
  symbol      TEXT NOT NULL,
  time        TIMESTAMPTZ NOT NULL,
  side        TEXT NOT NULL,            -- 'BUY' (short liquidated) | 'SELL' (long liquidated)
  price       NUMERIC(24, 12) NOT NULL,
  qty         NUMERIC(28, 8) NOT NULL,
  notional    NUMERIC(28, 8) GENERATED ALWAYS AS (price * qty) STORED,
  order_type  TEXT,
  status      TEXT
);
SELECT create_hypertable('liquidations', 'time', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX liquidations_symbol_time ON liquidations (symbol, time DESC);

-- aggTrades is high-volume. Persist *aggregated* CVD bars instead of raw trades to keep DB size sane.
CREATE TABLE cvd_bars (
  symbol           TEXT NOT NULL,
  interval         TEXT NOT NULL,       -- '1s' | '10s' | '1m'
  time             TIMESTAMPTZ NOT NULL,
  taker_buy_base   NUMERIC(28, 8) NOT NULL DEFAULT 0,
  taker_sell_base  NUMERIC(28, 8) NOT NULL DEFAULT 0,
  taker_buy_quote  NUMERIC(28, 8) NOT NULL DEFAULT 0,
  taker_sell_quote NUMERIC(28, 8) NOT NULL DEFAULT 0,
  trades           INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (symbol, interval, time)
);
SELECT create_hypertable('cvd_bars', 'time', chunk_time_interval => INTERVAL '7 days');

CREATE TABLE watchlist (
  symbol         TEXT PRIMARY KEY,
  added_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  pinned         BOOLEAN NOT NULL DEFAULT false,
  promoted_by    TEXT,                  -- 'oi_growth' | 'funding_z' | 'liq_volume' | 'manual'
  promoted_score NUMERIC(8, 4),
  last_active_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Retention: drop chunks older than 90 days for `cvd_bars` and `liquidations` (configurable), keep all others indefinitely. Use TimescaleDB community `add_retention_policy` (available in community).

## 2.3 Ingestion supervision tree

```
Counterflow.Ingest.Supervisor
├── Counterflow.Ingest.Registry                          (Registry, :unique)
├── Counterflow.Ingest.Universe.Supervisor               (one_for_one)
│   ├── Counterflow.Binance.WS.MarkPrice                 (single conn, all symbols)
│   ├── Counterflow.Binance.WS.Liquidations              (single conn, !forceOrder@arr)
│   ├── Counterflow.Binance.WS.UniverseKlines            (multi-stream, all syms × 1h)
│   ├── Counterflow.Ingest.RestPoller.Funding            (every 30s)
│   ├── Counterflow.Ingest.RestPoller.OpenInterestHist   (every 5m)
│   ├── Counterflow.Ingest.RestPoller.LSR                (every 5m, 3 sources)
│   └── Counterflow.Ingest.RestPoller.Ticker24h          (every 60s, drives promotion)
├── Counterflow.Ingest.Watchlist.Supervisor              (DynamicSupervisor)
│   └── (per-symbol child added/removed by Watchlist.Manager)
│       └── Counterflow.Ingest.SymbolWorker              (klines, aggTrade, depth subscriptions)
└── Counterflow.Ingest.Watchlist.Manager                 (rebalances every 5 min)
```

Symbol-worker supervision: `:rest_for_one` child spec — if the kline ws dies, restart aggTrade/depth too (they share state).

## 2.4 Watchlist auto-promotion

`Counterflow.Ingest.Watchlist.Manager` (GenServer, `:timer.send_interval(5 * 60_000, :rebalance)`):

```elixir
def handle_info(:rebalance, state) do
  candidates = Promotion.score_universe()  # returns [{symbol, score, reason}, ...]
  pinned = Repo.all(from w in Watchlist, where: w.pinned)

  current = Repo.all(from w in Watchlist, select: w.symbol) |> MapSet.new()
  target  = (Enum.take(candidates, 30 - length(pinned)) ++ Enum.map(pinned, &{&1.symbol, nil, "manual"}))
            |> Enum.map(&elem(&1, 0))
            |> MapSet.new()

  to_promote = MapSet.difference(target, current)
  to_demote  = MapSet.difference(current, target)

  Enum.each(to_promote, &start_symbol/1)
  Enum.each(to_demote, &stop_symbol/1)
  if MapSet.size(to_promote) > 0 or MapSet.size(to_demote) > 0 do
    Counterflow.Binance.WS.Watchlist.reconfigure(MapSet.to_list(target))
  end
  {:noreply, state}
end
```

`Promotion.score_universe/0` runs:

```sql
WITH oi_24h AS (
  SELECT symbol,
    last(open_interest, time) / first(open_interest, time) - 1 AS oi_growth_24h
  FROM open_interest
  WHERE time > now() - INTERVAL '24 hours'
  GROUP BY symbol
),
price_24h AS (
  SELECT symbol,
    abs(last(close, time) / first(open, time) - 1) AS price_move_24h
  FROM candles
  WHERE interval = '1h' AND time > now() - INTERVAL '24 hours'
  GROUP BY symbol
),
funding_z AS (
  SELECT symbol,
    abs((last(funding_rate, time) - avg(funding_rate)) /
         NULLIF(stddev(funding_rate), 0)) AS funding_z
  FROM funding_rates
  WHERE time > now() - INTERVAL '30 days'
  GROUP BY symbol
),
liq_pulse AS (
  SELECT symbol,
    sum(notional) FILTER (WHERE time > now() - INTERVAL '1 hour') /
    NULLIF(avg(sum(notional)) OVER (PARTITION BY symbol), 0) AS liq_ratio
  FROM liquidations
  WHERE time > now() - INTERVAL '30 days'
  GROUP BY symbol, time_bucket('1 hour', time)
)
-- combine signals, rank
```

Composite promotion score per symbol = `0.4 * normalize(oi_growth / max(price_move, 0.01)) + 0.3 * normalize(funding_z) + 0.3 * normalize(liq_ratio)`. Top N (N = 30 - pinned count) are promoted.

Hysteresis: a demoted symbol cannot be re-promoted within 30 min unless its score > demotion-time score by ≥ 25%. Prevents flapping.

## 2.5 Rate-limit budget

Binance USDT-M Futures limits: 2400 weight/min. Each endpoint has weight cost; we track via response headers (`X-MBX-USED-WEIGHT-1m`).

Budget allocation:
| Endpoint | Calls/min | Weight | Total/min |
|---|---|---|---|
| `openInterestHist` (× 30 watchlist) | 6 | 1 | 6 |
| `globalLongShortAccountRatio` (× 30 × 3 sources) | 18 | 1 | 18 |
| `topLongShortPositionRatio` (× 30) | 6 | 1 | 6 |
| `openInterest` (× 30 × 2 polls) | 60 | 1 | 60 |
| `premiumIndex` (single, all syms) | 2 | 1 | 2 |
| `ticker/24hr` (single, all syms) | 1 | 40 | 40 |
| Backfill bursts (klines) | up to 20 | 5 | 100 |
| **Total nominal** | | | **~232/min (10% of cap)** |

Plenty of headroom for expansion. `Counterflow.Binance.RateLimiter` is a GenServer that holds a token bucket and rejects/delays calls when reported weight crosses 1900/2400.

## 2.6 Backfill jobs (Oban)

On promotion of a new symbol, enqueue:
```elixir
%{symbol: "SOLUSDT", interval: "1m",  days: 30} |> BackfillKlines.new()  |> Oban.insert()
%{symbol: "SOLUSDT", interval: "5m",  days: 90} |> BackfillKlines.new()  |> Oban.insert()
%{symbol: "SOLUSDT", interval: "1h",  days: 365} |> BackfillKlines.new() |> Oban.insert()
%{symbol: "SOLUSDT"}                              |> BackfillOI.new()    |> Oban.insert()
%{symbol: "SOLUSDT"}                              |> BackfillLSR.new()   |> Oban.insert()
%{symbol: "SOLUSDT"}                              |> BackfillFunding.new() |> Oban.insert()
```

Oban queues:
- `:backfill` — concurrency 2 (respect rate limits)
- `:indicators` — concurrency 4 (Phase 3)
- `:default` — concurrency 8

`BackfillKlines` worker: pages backwards in 500-row chunks (`endTime` parameter), upserts. Resumable (checks DB for last persisted candle, only fetches gaps).

## 2.7 Liquidation firehose

Single ws to `wss://fstream.binance.com/ws/!forceOrder@arr`. Each event:
```json
{"e":"forceOrder","E":1568014460893,"o":{"s":"BTCUSDT","S":"SELL","o":"LIMIT","f":"IOC","q":"0.014","p":"9910","ap":"9910","X":"FILLED","l":"0.014","z":"0.014","T":1568014460893}}
```

Worker just inserts into `liquidations` and broadcasts `liquidations:firehose` PubSub for live UI heatmap.

## 2.8 Telemetry & ops

Required telemetry events:
- `[:counterflow, :ingest, :ws, :connected | :disconnected | :reconnecting]`
- `[:counterflow, :ingest, :rest, :request]` — measurement: `duration_ms, weight_used`
- `[:counterflow, :ingest, :persisted]` — measurement: `count`, metadata: `table, symbol`
- `[:counterflow, :watchlist, :rebalanced]` — metadata: `promoted, demoted`

Grafana dashboard (Phase 8 wires Prometheus exporter): per-symbol message rate, REST p99 latency, weight usage, DB insert rate, watchlist churn.

## 2.9 Out of scope for Phase 2
- Indicators (Phase 3)
- Strategy / signals (Phase 4)
- UI beyond minimal admin page showing what's flowing (full UI in Phase 5)
- Order book reconstruction beyond the partial-depth snapshot (full L2 book is Phase 9 if ever)

## Effort estimate
~7-10 days. The watchlist promotion logic and the multi-stream ws lifecycle are the trickiest parts; budget ample testing time on a private fork before pointing at live Binance.

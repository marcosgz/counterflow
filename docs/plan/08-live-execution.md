# Phase 8 — Live Execution (Testnet → Real)

**Goal:** Trade real money on Binance USDT-M Futures, gated by hard risk limits and preceded by 7 days of clean testnet runs.

**Exit criteria for Phase 8a (Testnet):**
- 7 consecutive days on Binance Futures testnet with zero state divergence between Counterflow's view and Binance's view (audit reconciliation hourly).
- All risk gates verified to engage correctly under simulated trigger conditions.
- User-data WS keepalive (listenKey refresh) survives 24h without manual intervention.

**Exit criteria for Phase 8b (Live):**
- Phase 7 walk-forward shows Sharpe ≥ 1.0, profit factor ≥ 1.4, max drawdown ≤ 15% on out-of-sample data.
- Phase 6 paper trading shows ≥ 60% of signals hitting TP1 over a 14-day live run.
- User has explicitly enabled `enable_live = true` in `symbol_strategy_config` for each symbol.
- Kill-switch tested manually before first live trade.

⚠️ **This phase trades real money. Every change requires user explicit approval. Defaults err on the side of disabling, never enabling.**

## 8.1 Testnet (Phase 8a)

`Counterflow.Broker.Testnet`:
- Base REST: `https://testnet.binancefuture.com`
- Base WS: `wss://stream.binancefuture.com`
- Separate API key/secret in env: `BINANCE_TESTNET_API_KEY`, `BINANCE_TESTNET_API_SECRET`
- Testnet API is API-compatible with prod for the endpoints we use; the `Counterflow.Broker.Testnet` impl is mostly a thin wrapper that swaps base URLs.

Flag-based selection in `config/runtime.exs`:
```elixir
config :counterflow, :broker_impl,
  case System.get_env("COUNTERFLOW_BROKER", "paper") do
    "paper"   -> Counterflow.Broker.Paper
    "testnet" -> Counterflow.Broker.Testnet
    "live"    -> Counterflow.Broker.Live
  end
```

Default in dev: `paper`. Default in production: `paper` until user explicitly sets `COUNTERFLOW_BROKER=testnet` or `=live`. **The flag must be set per-deploy; there is no UI toggle for this** (intentional friction).

## 8.2 Live broker (Phase 8b)

`Counterflow.Broker.Live`:
- Base REST: `https://fapi.binance.com`
- Base WS: `wss://fstream.binance.com`
- API key/secret: `BINANCE_API_KEY`, `BINANCE_API_SECRET` (read at boot, never logged).
- HMAC-SHA256 request signing per Binance docs.
- Idempotency: every order has a `newClientOrderId` = UUIDv7 (`<account>:<signal_id>:<intent>`) so retries never double-fill.

Endpoints used:
- `POST /fapi/v1/order` — place
- `DELETE /fapi/v1/order` — cancel
- `DELETE /fapi/v1/allOpenOrders` — emergency cancel-all
- `POST /fapi/v1/batchOrders` — batched bracket placement (entry + SL + TPs in one call)
- `GET /fapi/v2/account` — balance, positions, margin
- `GET /fapi/v1/openOrders` — reconciliation
- `POST /fapi/v1/listenKey` — start user-data ws
- `PUT /fapi/v1/listenKey` — keep-alive (every 30 min)

User-data WS at `wss://fstream.binance.com/ws/<listenKey>` delivers:
- `ACCOUNT_UPDATE`: balance + position changes
- `ORDER_TRADE_UPDATE`: order state transitions
- `ACCOUNT_CONFIG_UPDATE`: leverage changes
- `MARGIN_CALL`: warning before liquidation

## 8.3 Risk gates (defense in depth)

All gates are **hard-coded** and **fail-closed** — if any gate cannot evaluate (e.g., DB query fails), the order is **rejected**.

```elixir
defmodule Counterflow.Risk.Gates do
  @moduledoc "All gates must pass; any failure rejects the order."

  def check(order, account, signal) do
    with :ok <- killswitch_check(),
         :ok <- per_trade_risk_check(order, account),
         :ok <- daily_loss_check(account),
         :ok <- per_symbol_position_cap(order, account),
         :ok <- max_open_positions_check(account),
         :ok <- leverage_cap_check(order, signal),
         :ok <- price_divergence_check(order),
         :ok <- min_signal_score_check(signal),
         :ok <- symbol_filters_check(order),
         :ok <- whitelist_check(order),
         do: :ok
  end
end
```

Gate-by-gate:

| Gate | Default | Fail action |
|---|---|---|
| `killswitch_check` | env-var `COUNTERFLOW_KILL`, ETS flag, or `/admin/kill` engaged | reject all |
| `per_trade_risk_check` | risk ≤ 1% of equity | reject |
| `daily_loss_check` | -3% from day-start equity → 24h cooldown | reject |
| `per_symbol_position_cap` | $10k notional max per symbol (configurable) | reject |
| `max_open_positions_check` | ≤ 5 simultaneously open | reject |
| `leverage_cap_check` | ≤ 5× (10× requires explicit per-symbol override and admin confirmation) | reject |
| `price_divergence_check` | local mid vs Binance last-trade < 0.3% for 5s | reject (data quality issue) |
| `min_signal_score_check` | live: signal.score ≥ 0.65 (stricter than paper's 0.55) | reject |
| `symbol_filters_check` | Binance LOT_SIZE / PRICE_FILTER / MIN_NOTIONAL | reject (broker would 400 anyway) |
| `whitelist_check` | symbol must have `enable_live = true` | reject |

Gates are unit-tested by mocking each input and asserting only the failing path triggers reject. **Mocking is acceptable here** because we're testing gate logic, not strategy code.

## 8.4 Kill switches

Three layers:

1. **Process layer**: `Counterflow.Risk.KillSwitch` GenServer, holds boolean state in ETS. Checked synchronously before every order placement.

2. **Environment layer**: `COUNTERFLOW_KILL=1` at boot disables live broker entirely (returns `{:error, :killswitch}` for all calls). Toggleable at runtime via remote IEx.

3. **Operator layer**: `/admin/kill` LiveView page (admin-auth gated). Single button "ENGAGE KILL SWITCH" with confirmation modal. On click:
   - Set ETS flag.
   - Cancel all open orders via `DELETE /fapi/v1/allOpenOrders`.
   - Optional checkbox: "close all open positions at market" (default off).
   - Send Telegram + email alert (configured destinations).
   - Display "Kill switch engaged at <time> by <user>" banner sitewide.

Disengaging: also from `/admin/kill`, requires re-confirmation, logs the action. There is no automatic disengagement.

## 8.5 Reconciliation

Every 60 seconds (`Counterflow.Reconcile.Worker`):
1. Fetch `GET /fapi/v2/account` and `GET /fapi/v1/openOrders` from Binance.
2. Compare against local view in `live_positions` and `live_orders`.
3. If divergence detected (qty mismatch, missing order, stale state):
   - Log telemetry `[:counterflow, :reconcile, :divergence]` with details.
   - Treat Binance state as authoritative; update local DB.
   - If divergence > tolerance (e.g., position qty diff > 1% or > $100 notional), **engage killswitch** and alert.

Hourly: deeper reconciliation including last 100 user-data ws events vs Binance's `/fapi/v1/userTrades` for the last hour.

## 8.6 Schema (audit-grade, append-only)

```sql
CREATE TABLE live_orders (
  id              BIGSERIAL PRIMARY KEY,
  account_id      TEXT NOT NULL,                -- supports multi-account if user adds sub-accounts
  client_order_id TEXT NOT NULL UNIQUE,
  binance_order_id BIGINT,
  symbol          TEXT NOT NULL,
  side            TEXT NOT NULL,
  type            TEXT NOT NULL,
  qty             NUMERIC(28, 8) NOT NULL,
  price           NUMERIC(24, 12),
  stop_price      NUMERIC(24, 12),
  reduce_only     BOOLEAN,
  status          TEXT NOT NULL,
  signal_id       TEXT,
  intent          TEXT NOT NULL,                 -- 'entry' | 'sl' | 'tp1' | 'tp2' | 'manual_close' | 'risk_close'
  created_at      TIMESTAMPTZ NOT NULL,
  raw_request     JSONB NOT NULL,                -- audit
  raw_response    JSONB,                         -- audit
  last_event_at   TIMESTAMPTZ
);

CREATE TABLE live_fills (...);                    -- mirrors paper_fills
CREATE TABLE live_positions (...);                -- mirrors paper_positions
CREATE TABLE live_funding_payments (...);
CREATE TABLE killswitch_events (
  id          BIGSERIAL PRIMARY KEY,
  engaged_at  TIMESTAMPTZ NOT NULL,
  engaged_by  TEXT NOT NULL,
  reason      TEXT NOT NULL,
  released_at TIMESTAMPTZ,
  released_by TEXT
);
CREATE TABLE risk_rejections (
  id              BIGSERIAL PRIMARY KEY,
  attempted_at    TIMESTAMPTZ NOT NULL,
  signal_id       TEXT,
  symbol          TEXT,
  side            TEXT,
  rejected_by     TEXT NOT NULL,                  -- gate name
  details         JSONB
);
```

Every gate rejection is persisted to `risk_rejections` for review. Reviewing these is the primary feedback loop for tuning gates without disabling them.

## 8.7 LiveView `/live`

- **Top strip**: balance, equity, today's PnL, open positions count, open orders count, killswitch status (huge red banner if engaged).
- **Open positions** (read-only mostly): table with manual-close button (sends a market reduce_only order, also gated).
- **Open orders**: table with cancel button per order.
- **Recent fills** + **Recent rejections** side-by-side (rejections often more interesting for debugging).
- **Reconciliation status**: last reconcile time, last divergence detected.

## 8.8 Operational checklist (pre-live)

Before flipping `COUNTERFLOW_BROKER=live`:

- [ ] Phase 7 walk-forward report meets thresholds (Sharpe, drawdown, profit factor)
- [ ] Phase 6 14-day paper run passes
- [ ] Phase 8a 7-day testnet run completes without divergence
- [ ] Telegram + email alerts test-fired and received
- [ ] Kill switch engaged + disengaged successfully in dev
- [ ] API keys generated with **futures trade** + **read** permissions only (NO withdrawal permission)
- [ ] IP whitelist on Binance API key set to deployment server IP
- [ ] Daily loss cap and per-trade risk explicitly chosen (defaults are conservative; user may want tighter)
- [ ] Initial balance reduced to "amount you can lose without changing your life" — never the full account
- [ ] Off-site backup of audit DB scheduled
- [ ] Runbook for manual intervention written

User must check off each item in `/admin/golive-checklist` (a LiveView form). Until all checked, `COUNTERFLOW_BROKER=live` boots into killswitch-engaged state.

## 8.9 Out of scope for Phase 8
- Multiple sub-accounts (Phase 9).
- Cross-margin mode (we use isolated only — capped per-position liquidation risk).
- Hedge mode (one-way mode only for v1).
- Spot trading (Phase 9).

## Effort estimate
~10-14 days. The code surface is moderate; the *operational discipline* — testnet soak, gate verification, runbook drafting — is what consumes time. Do not compress this phase.

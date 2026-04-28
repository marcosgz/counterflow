# Phase 6 — Paper Trading

**Goal:** A faithful simulator that consumes signals, places "fake" orders against live tape, simulates fills with realistic slippage and fees, and tracks PnL with the same code path the eventual live broker will use.

**Exit criteria:**
- 14-day live paper run on the watchlist with full audit trail.
- Equity curve matches a manual spreadsheet recompute on a sampled trade (within rounding).
- Funding accruals match Binance's actual settlement on the same time window.
- LiveView `/paper` shows positions, equity, drawdown, fills in real time.

## 6.1 Broker behaviour

```elixir
defmodule Counterflow.Broker do
  @callback place_order(account_id :: String.t(), order :: Order.t()) ::
              {:ok, Acknowledgement.t()} | {:error, Error.t()}
  @callback cancel_order(account_id :: String.t(), order_id :: String.t()) :: :ok | {:error, term()}
  @callback positions(account_id :: String.t()) :: {:ok, [Position.t()]}
  @callback balance(account_id :: String.t()) :: {:ok, Decimal.t()}      # USDT
  @callback open_orders(account_id :: String.t()) :: {:ok, [Order.t()]}
end
```

Three implementations: `Counterflow.Broker.Paper` (this phase), `Counterflow.Broker.Testnet` (Phase 8a), `Counterflow.Broker.Live` (Phase 8b).

`Order.t()` and `Position.t()` are app-level structs that map to but are *not* Binance API structs (we keep abstraction so other exchanges can plug in later).

## 6.2 Paper broker architecture

```
┌──────────────────────────┐
│ Counterflow.Broker.Paper │
│ (one GenServer per       │
│  account, plus per-symbol│
│  order-book matchers)    │
└────────┬─────────────────┘
         │
         ├── account state (balance, positions, open orders) — held in GenServer + persisted
         ├── pending orders → handled by per-symbol Matcher GenServer
         │       │
         │       └── subscribes to `aggtrade:<symbol>` PubSub
         │           on each trade, evaluates open orders for fills
         │
         └── on fill → updates account state, emits PubSub `paper:account:<id>`,
                       persists fill to paper_fills, recalculates positions/PnL
```

## 6.3 Database schema

```sql
CREATE TABLE paper_accounts (
  id              TEXT PRIMARY KEY,
  initial_balance NUMERIC(20, 8) NOT NULL,
  balance         NUMERIC(20, 8) NOT NULL,    -- realized
  created_at      TIMESTAMPTZ DEFAULT now(),
  config          JSONB                        -- fee schedule, slippage model, max_leverage
);

CREATE TABLE paper_orders (
  id            BIGSERIAL PRIMARY KEY,
  account_id    TEXT REFERENCES paper_accounts(id),
  client_id     TEXT NOT NULL,
  symbol        TEXT NOT NULL,
  side          TEXT NOT NULL,           -- BUY | SELL
  position_side TEXT NOT NULL,           -- LONG | SHORT (hedge mode)
  type          TEXT NOT NULL,           -- MARKET | LIMIT | STOP_MARKET | TAKE_PROFIT_MARKET
  qty           NUMERIC(28, 8) NOT NULL,
  price         NUMERIC(24, 12),
  stop_price    NUMERIC(24, 12),
  reduce_only   BOOLEAN DEFAULT false,
  status        TEXT NOT NULL,           -- NEW | PARTIALLY_FILLED | FILLED | CANCELED | EXPIRED
  signal_id     TEXT,                    -- FK to signals
  placed_at     TIMESTAMPTZ NOT NULL,
  filled_at     TIMESTAMPTZ,
  filled_qty    NUMERIC(28, 8) DEFAULT 0,
  filled_avg    NUMERIC(24, 12)
);

CREATE TABLE paper_fills (
  id           BIGSERIAL PRIMARY KEY,
  order_id     BIGINT REFERENCES paper_orders(id),
  account_id   TEXT REFERENCES paper_accounts(id),
  symbol       TEXT NOT NULL,
  side         TEXT NOT NULL,
  price        NUMERIC(24, 12) NOT NULL,
  qty          NUMERIC(28, 8) NOT NULL,
  fee          NUMERIC(20, 8) NOT NULL,
  filled_at    TIMESTAMPTZ NOT NULL,
  realized_pnl NUMERIC(20, 8)        -- on close fills only
);

CREATE TABLE paper_positions (
  id            BIGSERIAL PRIMARY KEY,
  account_id    TEXT REFERENCES paper_accounts(id),
  symbol        TEXT NOT NULL,
  position_side TEXT NOT NULL,
  qty           NUMERIC(28, 8) NOT NULL,        -- 0 means closed
  entry_avg     NUMERIC(24, 12) NOT NULL,
  leverage      INTEGER NOT NULL,
  opened_at     TIMESTAMPTZ NOT NULL,
  closed_at     TIMESTAMPTZ,
  realized_pnl  NUMERIC(20, 8) DEFAULT 0,
  funding_paid  NUMERIC(20, 8) DEFAULT 0,
  signal_id     TEXT,
  UNIQUE(account_id, symbol, position_side, opened_at)
);

CREATE TABLE paper_funding_payments (
  id              BIGSERIAL PRIMARY KEY,
  account_id      TEXT REFERENCES paper_accounts(id),
  position_id     BIGINT REFERENCES paper_positions(id),
  symbol          TEXT NOT NULL,
  funding_rate    NUMERIC(12, 8) NOT NULL,
  notional        NUMERIC(20, 8) NOT NULL,
  amount          NUMERIC(20, 8) NOT NULL,        -- positive = paid, negative = received
  applied_at      TIMESTAMPTZ NOT NULL
);
```

## 6.4 Slippage model

Default model (`Counterflow.Broker.Paper.Slippage.Linear`):

```elixir
defmodule Counterflow.Broker.Paper.Slippage.Linear do
  # slippage_bps = base + impact_coef * (order_qty / typical_1m_volume)
  @base_bps 1.0          # 1 bp baseline (spread approximation)
  @impact_coef 50.0      # bps per "1.0 of typical volume"

  def apply(order, last_trade_price, typical_volume_1m) do
    impact = @impact_coef * (Decimal.to_float(order.qty) / Decimal.to_float(typical_volume_1m))
    bps = @base_bps + impact

    direction = if order.side == :buy, do: 1, else: -1
    last_trade_price |> Decimal.mult(Decimal.from_float(1 + direction * bps / 10_000))
  end
end
```

For watchlist symbols at typical sizes ($100-$1000 notional on a major), this gives 1-3 bp slippage — realistic for VIP-0 retail. Configurable per account.

## 6.5 Fill simulation

Market orders: fill on the next `aggtrade:<symbol>` event after order placement. Fill price = slippage-adjusted last trade price. Single fill (no partial fills for paper, even if size > tape — accept slight unrealism in exchange for simplicity).

Limit orders: queue in the Matcher GenServer's symbol order book. On each aggTrade:
- BUY limit fills if a SELL aggTrade prints at price ≤ limit.
- SELL limit fills if a BUY aggTrade prints at price ≥ limit.
- Maker fee applies (-0.02% on Binance VIP-0 USDT-M, i.e., a rebate).

Stop orders (`STOP_MARKET`, `TAKE_PROFIT_MARKET`): converted to MARKET orders when the stop_price is touched (any aggTrade through the level). Once triggered, fill on the *next* aggTrade with slippage applied.

Time-in-force: only `GTC` and `IOC` for paper. `IOC` cancels remainder if not filled within 1 second.

## 6.6 Fees

VIP-0 USDT-M Futures: 0.04% taker, 0.02% maker (rebate on maker can be toggled if user has BNB fee discount enabled). Stored per-account in `paper_accounts.config`.

Fees deducted from realized PnL on every fill, persisted to `paper_fills.fee`.

## 6.7 Funding payments

Every 8 hours (00:00, 08:00, 16:00 UTC):
- For each open position, compute `funding_amount = position.qty * mark_price * funding_rate * direction_sign`.
- Where `direction_sign`: long pays when funding > 0, receives when funding < 0; short reversed.
- Persist to `paper_funding_payments`, deduct/credit from `paper_accounts.balance`, increment `paper_positions.funding_paid`.

Implementation: Oban cron job at the three settlement times. Reads `funding_rates` table (already populated by Phase 2) and active positions.

## 6.8 PnL math

Per position:
- **Unrealized PnL** = `qty * (mark_price - entry_avg) * direction_sign` (long: 1, short: -1). Updated on every mark price tick (PubSub `mark_price:<symbol>`).
- **Realized PnL** = sum of `(close_price - entry_avg) * direction_sign * close_qty - fees - funding_paid` across all close fills.

Account equity = balance + sum(unrealized PnL across positions).

Drawdown = `(peak_equity - current_equity) / peak_equity`.

Sharpe (simple, daily): mean(daily_returns) / stddev(daily_returns) * sqrt(365).

## 6.9 Position sizing

When a signal arrives and `paper.enabled = true` for that symbol:

```elixir
defmodule Counterflow.Broker.Paper.Sizer do
  @per_trade_risk_pct 0.01         # 1% of equity at risk per trade

  def size(account, signal) do
    equity = balance(account.id) |> add_unrealized()
    risk_amount = Decimal.mult(equity, Decimal.from_float(@per_trade_risk_pct))
    r_pct = Decimal.div(Decimal.abs(Decimal.sub(signal.price, signal.sl)), signal.price)
    notional = Decimal.div(risk_amount, r_pct)
    leverage = min(signal.leverage_suggested, account.config.max_leverage)
    qty = Decimal.div(Decimal.mult(notional, Decimal.new(leverage)), signal.price)
    apply_lot_filter(signal.symbol, qty)
  end
end
```

`apply_lot_filter/2` rounds down to the symbol's `LOT_SIZE.stepSize` (loaded from `exchangeInfo`).

## 6.10 Strategy → broker bridge

```elixir
defmodule Counterflow.Bridge.SignalToOrder do
  use GenServer

  def init(_) do
    Phoenix.PubSub.subscribe(Counterflow.PubSub, "signals:new")
    {:ok, %{}}
  end

  def handle_info({:signal, signal}, state) do
    if paper_enabled?(signal.symbol) do
      Counterflow.Broker.Paper.execute_signal("paper-default", signal)
    end
    # Phase 8 will add live execution here
    {:noreply, state}
  end
end
```

`execute_signal/2`:
1. Size the position.
2. Place entry as MARKET (or LIMIT at signal.price ± 0.05% — configurable).
3. Place SL as STOP_MARKET reduce_only.
4. Place TP1 as TAKE_PROFIT_MARKET reduce_only at signal.tp1 for 50% of qty.
5. Place TP2 as TAKE_PROFIT_MARKET reduce_only at signal.tp2 for remaining 50%.
6. On TP1 hit: cancel SL, replace with breakeven SL at entry price.

This is "trade management 101" — robust, no creative add-ons.

## 6.11 LiveView `/paper`

- **Top strip**: equity curve (last 30d), current balance, current equity, daily PnL, max drawdown, total trades, win rate, profit factor.
- **Open positions table**: symbol, side, qty, entry, mark, unrealized PnL, leverage, age, signal link, manual-close button.
- **Recent fills**: last 50, paginated.
- **Trade journal**: closed positions with entry/exit, pnl, signal context, R-multiple. Click to expand chart-with-markers replay (reads from `candles` table).

## 6.12 Out of scope for Phase 6
- Multi-account simulations (Phase 7 backtest creates separate accounts).
- Hedge mode UX (paper supports it under the hood, but UI presents one-way only for v1).
- Order grouping (OCO, brackets) — we emulate brackets via the SL/TP/manual-cancel logic above.

## Effort estimate
~7-10 days. The matcher and slippage model are mechanical. The trade-management state machine (TP1 → SL-to-breakeven, TP2 close) is where most bugs hide; budget extensive integration tests against synthetic aggTrade streams.

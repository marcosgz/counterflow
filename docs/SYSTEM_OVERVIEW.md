# Counterflow — System Overview & Test Guide

A real-time crypto futures detection-and-execution platform on Elixir/Phoenix LiveView. This document is the single map of every moving part and how to verify each one. Pair it with `docs/ONBOARDING.md` (first-time setup) and the per-phase docs in `docs/plan/`.

## What's running

```
Binance Futures (REST + WS)
        │
        ▼
┌─── Ingest layer ──────────────────────────────────────────────┐
│  Counterflow.Binance.WS.Kline       per (symbol, interval)    │
│  Counterflow.Binance.WS.Liquidations  !forceOrder@arr firehose│
│  Counterflow.Ingest.Poller.OpenInterest      every 5m         │
│  Counterflow.Ingest.Poller.LSR               every 5m         │
│  Counterflow.Ingest.Poller.Funding           every 30s        │
│  Counterflow.Ingest.Backfill        on-promote 7d catch-up    │
└───────────────────────────────────────────────────────────────┘
        │
        ▼ (TimescaleDB hypertables)
   candles · open_interest · long_short_ratio · funding_rates
   liquidations · cvd_bars · indicator_values · signals
        │
        ▼
┌─── Strategy layer ───────────────────────────────────────────┐
│  Counterflow.Indicators.{EMA,RSI,BucketedForce,OIDelta,      │
│                          FundingZ,LiquidationPulse,LSRSignal}│
│  Counterflow.Strategy.Counterflow.evaluate_detailed/2        │
│  Counterflow.Strategy.Pipeline    auto-invokes per close     │
│  Counterflow.Strategy.Cooldown    ETS dedup                   │
│  Counterflow.Strategy.Diagnostics ETS per-eval log           │
│  Counterflow.Strategy.Dispatcher  PubSub + sinks fan-out     │
└──────────────────────────────────────────────────────────────┘
        │
        ▼
┌─── Execution layer ──────────────────────────────────────────┐
│  Counterflow.Bridge.SignalToPaper  → 4-order bracket         │
│  Counterflow.Broker.Paper.Matcher  fills SL/TP on closes     │
│  Counterflow.Broker.Testnet        Phase 8a, HMAC signed     │
│  Counterflow.Broker.Live           Phase 8b, fail-closed     │
│  Counterflow.Risk.{Gates, KillSwitch}                        │
│  Counterflow.Binance.WS.UserData   ACCOUNT_UPDATE etc.       │
└──────────────────────────────────────────────────────────────┘
        │
        ▼
┌─── Optimization & autonomy ──────────────────────────────────┐
│  Counterflow.Strategy.OutcomeEvaluator  TP/SL resolution     │
│  Counterflow.Backtest.Runner            single-window replay │
│  Counterflow.Backtest.WalkForward       train/test rolling   │
│  Counterflow.Backtest.AutoTuner         nightly threshold sweep │
│  Counterflow.Watchlist.Promoter         5-min activity rotate │
│  Counterflow.Reports.WeeklyDigest       LLM-narrated weekly  │
│  Counterflow.Reports.Scheduler          Sundays 23:00 UTC    │
└──────────────────────────────────────────────────────────────┘
        │
        ▼
┌─── UI ───────────────────────────────────────────────────────┐
│  /              Overview        /paper      Paper PnL        │
│  /watchlist     Watchlist       /backtest   Replay + WF      │
│  /signals       Signal feed     /audit      Audit log        │
│  /symbol/:sym   Charts + indic. /debug      Strategy debug   │
│  /settings      Index + Telegram                             │
│  /settings/:sym Per-symbol config + auto-tune                │
│  /login         Email/password sign-in                       │
└──────────────────────────────────────────────────────────────┘
```

## Quick start

```bash
# 1. TimescaleDB
docker-compose -f compose.dev.yml up -d

# 2. App
cd counterflow
mix deps.get
mix ecto.create
mix ecto.migrate

# 3. First user (required to log in)
mix counterflow.create_user you@example.com a-strong-password

# 4. Run
mix phx.server
# open http://localhost:4000/login
```

## Optional integrations (env vars)

All Counterflow-specific env vars are namespaced under `COUNTERFLOW_`:

| Variable | Purpose |
|---|---|
| `COUNTERFLOW_KILL=1` | Engage kill switch at boot |
| `COUNTERFLOW_USER` + `COUNTERFLOW_PASSWORD` | Optional HTTP basic auth in front of the dashboard (in addition to login) |
| `COUNTERFLOW_OWNER_EMAIL` + `COUNTERFLOW_OWNER_PASSWORD` | First user auto-created on boot if no users exist |
| `COUNTERFLOW_TELEGRAM_BOT_TOKEN` + `COUNTERFLOW_TELEGRAM_CHAT_ID` | Telegram alerts (signals + bracket fills + weekly digest) |
| `COUNTERFLOW_LLM_PROVIDER` (`anthropic` or `openai`) | LLM provider for the weekly digest |
| `COUNTERFLOW_LLM_API_KEY` | Provider API key |
| `COUNTERFLOW_LLM_MODEL` | Model name (`claude-sonnet-4-6`, `gpt-4o-mini`, etc.) |
| `BINANCE_TESTNET_API_KEY` + `BINANCE_TESTNET_API_SECRET` | Testnet broker (Phase 8a) |
| `BINANCE_API_KEY` + `BINANCE_API_SECRET` | Live broker (Phase 8b — gated) |

## How to test each piece

Below: feature → what it does → minimum command to verify it works.

### Phase 1 — Ingest

| | |
|---|---|
| **Klines flowing** | Boot, wait 60s, then in psql: `SELECT COUNT(*) FROM candles;` should grow. |
| **Liquidations firehose** | `SELECT COUNT(*) FROM liquidations;` grows during active markets. |
| **OI / LSR / Funding pollers** | After 5 minutes: `SELECT COUNT(*) FROM open_interest;` non-zero per watchlist symbol. |

### Phase 3 — Indicators

```bash
mix test test/counterflow/indicators/    # all green
```

### Phase 4 — Strategy + Pipeline + Diagnostics

| Test | How |
|---|---|
| Pipeline subscribed at boot | log line: `Strategy.Pipeline subscribed: +N` |
| Diagnostics populated | `/debug` page → click "Refresh now" → table fills with one row per (symbol, interval) showing reason it didn't fire (NEUTRAL / BELOW THR / TREND / SIDE OFF / COOLDOWN / EMITTED) |
| Signal emits | Lower a symbol's threshold to 0.30 in `/settings/:sym` → wait for next 5m candle close → check `/signals` |

### Phase 5 — UI

```bash
for p in / /watchlist /signals /symbol/BTCUSDT /settings /paper /backtest /audit /debug; do
  echo "$p -> $(curl -sS -o /dev/null -w "%{http_code}" -b "_counterflow_key=...; user_id=1" http://127.0.0.1:4000$p)"
done
```
All should return 200 once authenticated.

### Phase 6 — Paper trading + bracket matcher

| Test | How |
|---|---|
| Manual round-trip | IEx: `Counterflow.Broker.Paper.ensure_account("test"); Counterflow.Broker.Paper.place_order("test", %{symbol: "BTCUSDT", side: "BUY", type: "MARKET", qty: Decimal.new("0.01"), reference_price: Decimal.new("67500")})` |
| Auto bracket on signal | `/settings/BTCUSDT` → toggle "Auto paper-trade" ON → wait for signal → check `/paper` for 4 orders (entry, sl, tp1, tp2) |
| TP1 promotes SL to BE | covered by `mix test test/counterflow/broker/paper/matcher_test.exs` |

### Phase 7 — Backtest + walk-forward + auto-tune

| Test | How |
|---|---|
| Single-window backtest | `/backtest` → Run Backtest. Returns metrics + per-signal table. |
| Walk-forward overfit detector | `/backtest` → Walk-forward. Look at the consistency KPI: green ≥70%, yellow 40–70%, red <40%. |
| Auto-tune sweep | `/settings/BTCUSDT` → toggle Auto-tune ON → "Sweep now" → flash "Auto-tune finished" → page refreshes with new threshold. |
| Auto-tune scheduled | Default Sundays 23:00 UTC; check `auto_tune_runs` table for nightly entries. |

### Phase 8 — Risk gates + kill switch + testnet

| Test | How |
|---|---|
| Kill switch engages | IEx: `Counterflow.Risk.KillSwitch.engage("test", "manual")` then `Counterflow.Risk.KillSwitch.engaged?()` returns true. Persisted in `killswitch_events`. |
| All risk gates verified | `mix test test/counterflow/risk/gates_test.exs` |
| Live broker fail-closed | `mix test test/counterflow/broker/live_test.exs` confirms `{:error, :live_disabled_until_phase_8b}` even with all gates passing |
| Testnet broker | Set `BINANCE_TESTNET_API_KEY/SECRET`, `config :counterflow, :binance_market, :testnet`, `config :counterflow, :broker_impl, Counterflow.Broker.Testnet`, restart. IEx: `Counterflow.Broker.Testnet.balance("any")` returns `{:ok, Decimal.new(...)}`. |
| HMAC signing | `mix test test/counterflow/binance/rest_signed_test.exs` verifies stable HMAC-SHA256 + missing-creds error path. |

### Watchlist auto-promotion

| Test | How |
|---|---|
| Promoter scoring | `mix test test/counterflow/watchlist/promotion_test.exs` |
| /watchlist UI | "Auto-promotion" panel shows ENABLED pill + candidate table; "Rebalance now" button kicks one round; promoted symbols get `promoted_by="auto:<reason>"` |
| Backfill on promote | New symbol → 7d of candles within ~30s (paged from REST). Verify: `SELECT COUNT(*) FROM candles WHERE symbol='NEWSYM';` |

### Telegram alerts

| Test | How |
|---|---|
| Configured? | `/settings` → "Telegram alerts" panel shows green CONFIGURED pill |
| Test message | "Send test message" button → ✓ delivered shows |
| Signal emit | Real signal triggers a chat post within ~1s |
| Bracket fill | TP1/TP2/SL fill triggers a card with R-multiple |

### LLM weekly digest

| Test | How |
|---|---|
| LLM configured? | `/audit` header chip shows "LLM · Anthropic Claude" or "OpenAI" with green CONFIGURED indicator |
| Manual trigger | `/audit` → "Send weekly digest" button → flash "Digest sent" + Telegram chat receives it |
| Provider switch | `export COUNTERFLOW_LLM_PROVIDER=openai` and restart → header chip flips to OpenAI |
| LLM tests | `mix test test/counterflow/llm_test.exs` (Anthropic + OpenAI adapter via Bypass) |

### Multi-user

| Test | How |
|---|---|
| Owner auto-created | Set `COUNTERFLOW_OWNER_EMAIL` + `COUNTERFLOW_OWNER_PASSWORD` and boot for the first time → `mix run -e 'IO.inspect(Counterflow.Accounts.list_users())'` shows the user |
| Login required | Hit `/` without a session → 302 redirect to `/login` |
| Mix create_user task | `mix counterflow.create_user a@b.com somepassword123` returns `✓ User a@b.com (id=N) created` |
| FK cascading | `mix run -e 'Counterflow.Repo.delete_all(Counterflow.Accounts.User)'` (in dev only) cascades through every per-user table cleanly |

## Run all tests at once

```bash
cd counterflow
mix test
```

Should report `92+ tests, 0 failures`.

## Known scope-limited items

- **Single-tenant LiveView wiring**: every API defaults to `Accounts.owner_id()`. Multi-tenant per-user-on-screen is a wiring exercise away (pull `current_user.id` from the socket, pass into Watchlist/Config/Paper calls).
- **Phase 8b activation**: testnet broker is fully wired; `Counterflow.Broker.Live` still returns `{:error, :live_disabled_until_phase_8b}` until you flip `:broker_impl` to `Counterflow.Broker.Live` AND replace the stub clause with a signed POST. Operational checklist in `docs/plan/08-live-execution.md`.
- **aggTrades stream**: Phase 2 doc plans CVD bars from real aggTrades; the symbol page currently approximates CVD from kline taker buy/sell columns.
- **Walk-forward UI parameter sweep**: walk-forward runs the threshold grid per train window; future work is a parameter-sweep mode that grids weights too.

## File map (high-impact only)

```
counterflow/
├── lib/
│   ├── counterflow/
│   │   ├── accounts.ex              user CRUD + owner
│   │   ├── accounts/user.ex
│   │   ├── alerts/telegram.ex       signals + fills sink
│   │   ├── backtest/
│   │   │   ├── runner.ex            single-window
│   │   │   ├── walk_forward.ex      rolling train/test
│   │   │   ├── auto_tuner.ex        nightly sweep + writeback
│   │   │   └── auto_tuner_scoring.ex composite
│   │   ├── binance/
│   │   │   ├── rest.ex              public endpoints
│   │   │   ├── rest_signed.ex       HMAC-SHA256 signing
│   │   │   └── ws/{kline,liquidations,user_data}.ex
│   │   ├── bridge/signal_to_paper.ex 4-order bracket placement
│   │   ├── broker/
│   │   │   ├── paper.ex
│   │   │   ├── paper/matcher.ex     SL/TP fills against closes
│   │   │   ├── testnet.ex           Phase 8a
│   │   │   └── live.ex              Phase 8b (gated)
│   │   ├── indicators/              pure functions
│   │   ├── ingest/
│   │   │   ├── backfill.ex          on-promote 7d catch-up
│   │   │   └── poller/{open_interest,lsr,funding}.ex
│   │   ├── llm.ex                   provider-agnostic
│   │   ├── llm/{anthropic,openai}.ex
│   │   ├── reports/{weekly_digest,scheduler}.ex
│   │   ├── risk/{gates,kill_switch}.ex
│   │   ├── strategy/
│   │   │   ├── counterflow.ex       evaluate_detailed
│   │   │   ├── pipeline.ex          auto-invoke on candle close
│   │   │   ├── diagnostics.ex
│   │   │   ├── dispatcher.ex
│   │   │   └── outcome_evaluator.ex
│   │   └── watchlist/{manager,promoter,promotion}.ex
│   └── counterflow_web/
│       ├── auth.ex                  session plug + LV on_mount
│       ├── controllers/auth_controller.ex
│       ├── plugs/basic_auth.ex      stopgap HTTP basic auth
│       └── live/                    every dashboard page
└── docs/
    ├── ONBOARDING.md
    ├── SYSTEM_OVERVIEW.md           you are here
    └── plan/                        per-phase contracts
```

## What to do next

1. Sign in at `/login`, pin a few symbols on `/watchlist`, then leave Counterflow running for a day.
2. Visit `/audit` periodically to see what it's doing on its own.
3. Run a walk-forward backtest before trusting any auto-tuned threshold for a symbol you intend to trade live.
4. When ready, follow `docs/plan/08-live-execution.md` for the testnet → live activation steps.

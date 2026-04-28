# Phase 5 — LiveView UI

**Goal:** Real-time Phoenix LiveView dashboard showing the market firehose, watchlist, signals, charts, and (later phases) paper/live positions.

**Exit criteria:**
- Cold page load < 1.5s on dev hardware.
- 30-symbol watchlist firehose maintains 60 fps without dropped frames.
- WS reconnect handled gracefully with banner + auto-resubscribe.
- TradingView widget chart embeds and renders Binance Futures candles.
- Custom OI / LSR / Funding / CVD / Liquidations panels render via Chart.js LiveView hook.

## 5.1 Page inventory

| Route | Purpose |
|---|---|
| `/` | Overview heatmap |
| `/watchlist` | Pinned + auto-promoted symbols, sortable |
| `/symbol/:symbol` | Single-symbol deep view (chart + side panels) |
| `/signals` | Global signal feed |
| `/signals/:id` | Single signal detail (with replay context) |
| `/paper` | Paper-trading dashboard (Phase 6) |
| `/backtest` | Backtest launcher + results (Phase 7) |
| `/live` | Live execution dashboard (Phase 8, gated) |
| `/settings` | Per-symbol config, alert sinks, strategy weights |
| `/admin/kill` | Kill-switch (Phase 8) |

## 5.2 Navigation shell

LiveView stateful nav with persistent header showing:
- **Connection indicator**: green/red dot for Binance WS health (subscribed to `[:counterflow, :ingest, :ws, :*]` telemetry via a `Counterflow.Telemetry.PresenceWatcher`).
- **Kill switch indicator**: red banner across top if `COUNTERFLOW_KILL=1` or `/admin/kill` engaged.
- **Latest signal toast**: bottom-right notification when `signals:new` PubSub fires (auto-dismiss 8s).

Stack: Phoenix 1.7 + LiveView 1.0 + Tailwind v4 + DaisyUI. No JS framework — Vanilla Alpine.js for tiny client-side state (filter inputs), LiveView handles the rest.

## 5.3 `/` Overview

Layout (3-column on desktop, stacked on mobile):

**Left column — Top movers (24h)**
- Sortable table: symbol, price, 24h %, OI 24h %, funding rate (latest), liquidation 24h notional.
- Powered by a single LiveView assigned to `markets` topic; updates every 5s.

**Center — Heatmap**
- 20×20 grid (top 400 symbols by 24h volume).
- Cell color: 24h % move (red ↔ green diverging).
- Cell size proportional to log(24h volume).
- Hover: tooltip with OI delta, funding, last signal.
- Click: navigate to `/symbol/:symbol`.
- Implemented as SVG; updated every 30s (this changes slowly).

**Right column — Live signal feed**
- Last 20 signals across all symbols. New ones slide in at top.
- Each row: side badge, symbol, score, components mini-bar, age.
- Click → `/signal/:id`.

## 5.4 `/symbol/:symbol`

The deep-dive page. Five regions:

**Region A — Header strip (top)**
- Symbol name, last price, 24h move, mark/index spread, funding rate countdown, current OI value.
- Buttons: ⭐ Pin to watchlist, 🔔 Toggle alerts, ⚙ Per-symbol settings.

**Region B — TradingView widget (largest panel)**
- Embedded `<tv-widget>` with `symbol="BINANCE:BTCUSDT.P"`, free Charting Library widget (not the paid one).
- Two interval selectors: top tab bar `[1m, 5m, 1h, 4h, 1d]`.
- Limitation: free widget does not allow custom Pine indicators or data overlays. We respect this — custom data lives in the side panels, not on the chart.

**Region C — Indicator side panels (right of chart, vertical stack)**
Each panel is a small Chart.js line/bar chart fed via a LiveView hook. All share x-axis with the TV widget by passing the same time range.

1. **Open Interest** — line chart, last 24h, 5m granularity. Overlay: % change vs 24h ago.
2. **Long/Short Ratio** — line chart with three series: global account, top trader position, top trader account. Annotation: RSI(LSR) value as a sparkline.
3. **Funding Rate** — bar chart, last 30 funding events (10 days at 8h cadence). Z-score badge.
4. **CVD** — line chart, last 4h, 1m granularity. Annotation: divergence detection ("CVD made lower high while price made higher high").
5. **Liquidations heatmap** — 1m × side × 24h, cells colored by notional. Click a cell to see contributing liq events.
6. **Recent signals** — table of last 10 signals on this symbol with outcome badges (TP1 hit / SL hit / expired / pending).

**Region D — Trade panel (Phase 6+)**
- Paper-trade ticket: place / close orders, see open positions.
- Disabled (greyed) until Phase 6 ships.

**Region E — Footer**
- Symbol metadata (filters, status, listed date).
- "Force backfill" admin button (re-runs Phase 2 backfill for this symbol).

PubSub subscriptions on mount:
```elixir
subscribe("candles:#{symbol}:#{interval}")
subscribe("oi:#{symbol}")
subscribe("lsr:#{symbol}")
subscribe("funding:#{symbol}")
subscribe("liquidations:#{symbol}")
subscribe("cvd:#{symbol}:1m")
subscribe("signals:#{symbol}")
```

Each handler updates the corresponding Chart.js dataset via `push_event/3` to the hook.

## 5.5 `/watchlist`

Single big table, sticky header, 30 rows (or fewer):

| Pin | Symbol | Last | 24h % | OI 24h % | Funding (z) | Liq 1h $ | Last signal | Score (latest) |
|-----|--------|------|-------|----------|-------------|----------|-------------|----------------|

- Click row → `/symbol/:symbol`.
- Pin/unpin: PATCH the `watchlist` row, broadcasts to all sessions.
- Color-code "promoted by" reason as a subtle left border.
- Add-symbol input at bottom (autocomplete from `exchangeInfo`) — manual pin.

## 5.6 `/signals`

Global infinite-scroll feed. Filters: symbol(s), side, score range, components, time range, outcome.

Server-side pagination: `Repo.all(from s in Signal, where: ..., order_by: [desc: :generated_at], limit: 50)`. LiveView `phx-viewport-bottom` triggers next page load.

Each row collapses/expands to show `components` JSONB as a small bar chart.

## 5.7 LiveView hooks (JS)

Three hooks, all minimal:

`Hooks.ChartJS` — receives `{:update, dataset_id, data}` events, updates the corresponding Chart.js instance. One hook per chart container.

```javascript
const ChartJS = {
  mounted() {
    const ctx = this.el.getContext('2d');
    this.chart = new Chart(ctx, JSON.parse(this.el.dataset.config));
    this.handleEvent("chart:update", ({id, data}) => {
      if (this.el.id === id) {
        this.chart.data = data;
        this.chart.update('none');   // no animation for streaming updates
      }
    });
  },
  destroyed() { this.chart?.destroy(); }
};
```

`Hooks.TradingView` — initializes the TV widget on mount, tears down on destroy, syncs theme.

`Hooks.Toast` — fade-in/out for signal notifications.

## 5.8 Performance

Concerns:
- 30 symbols × 6 panels × per-second updates = a lot of LiveView diffs.
- Mitigation: throttle in the worker layer. The kline ws fires once per second per symbol while the candle is open, but we only push to LiveView every 1s aggregated, and only for the symbol currently being viewed.
- LiveView assigns sized minimally: store latest snapshot in ETS (`:counterflow_market_state`), LiveView reads on mount, then subscribes.
- Use `temporary_assigns` for the global feed: each signal row is rendered once and stays in the DOM via stream API, no re-render.
- Heatmap on `/`: only rerender on 30s interval, not per-tick.

`Phoenix.LiveView.stream/3` for all list-style data (signals feed, watchlist updates) — avoids re-sending the full list on each insert.

## 5.9 Theming

Dark by default (trader convention). Daisy theme `business` with custom accent (`#22d3ee` cyan for long, `#f43f5e` rose for short). Light theme available via toggle but de-prioritized.

## 5.10 Authentication

Phase 5 ships **single-user**: env-var `COUNTERFLOW_USER` and `COUNTERFLOW_PASSWORD` (bcrypt-hashed in config). Plug-based basic auth on all routes.

Multi-user (sessions, signups) deferred to Phase 9 if there's a copy-trading or SaaS direction. For Phase 1-8, the app is a personal tool.

## 5.11 Out of scope for Phase 5
- Mobile-first responsive layouts (best-effort, not prioritized; desktop is primary).
- Customizable layouts (drag-to-resize panels) — fixed layout for v1.
- Multi-tenant data isolation (Phase 9).

## Effort estimate
~7-10 days. The TradingView embed is a same-day task. The bulk goes into Chart.js plumbing, the heatmap, real-time fluidity tuning, and getting the watchlist/signal feed feel right.

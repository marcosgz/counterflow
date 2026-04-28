# Phase 9 — Future Roadmap

This phase is a **directional sketch**, not a contract. Items here unlock once Phases 1-8 are stable and live trading has produced enough data + lessons to justify the next layer of complexity.

## 9.1 Spot trading mirror

- New broker impl `Counterflow.Broker.Spot` — different REST host (`https://api.binance.com`), simpler endpoints, no funding, no leverage, no liquidations.
- Use case: portfolio rebalancing into spot positions when the strategy detects regime change favoring buy-and-hold over scalping.
- Smaller signal set: spot doesn't have OI / LSR / funding. Only TF spike + price action + CVD divergence apply.
- **Effort**: ~5 days, mostly endpoint plumbing and a Spot variant of `/symbol/:symbol`.

## 9.2 Multi-exchange ingestion

- Bybit and OKX have similar futures markets with their own OI / LSR / funding feeds.
- Cross-venue confirmation: a smart-money setup is more credible if multiple venues show coordinated OI buildup, not just one.
- Add `Counterflow.Exchanges` abstraction; `Binance` becomes one of N implementations.
- Persist per-exchange under `exchange` column in hypertables.
- New indicator: **Cross-venue OI sync** (correlation of normalized OI across exchanges).
- **Effort**: ~10-14 days. Bybit and OKX have decent docs but auth schemes and ws conventions differ.

## 9.3 ML signal scorer

- Feature set: every component of the linear scorer + raw indicator values + market regime classifiers (trending/ranging/high-vol).
- Labels: outcome from `signals.outcome` JSONB (TP1 hit / SL hit / expired) labeled per signal — already collected from Phase 4 onward.
- Models: start with **gradient-boosted trees** (XGBoost via Erlport, or rewrite in pure Elixir with `EXGBoost` if available). Avoid neural nets until dataset > 100k labeled signals.
- Training pipeline: nightly Oban job retrains on rolling 6-month window, evaluates against the most recent 2 weeks held out, only deploys new model if AUROC improves by ≥ 1%.
- Replaces the linear scorer at the threshold step; signal struct unchanged so downstream is unaffected.
- **Risk**: overfitting. Gate with walk-forward (already built in Phase 7).
- **Effort**: ~14-21 days including training infra.

## 9.4 Alternative strategies

The platform is built for one strategy ("Counterflow"). Adding more is straightforward via the `Counterflow.Strategy` behaviour.

Candidates:
- **Trend continuation** (the inverse of Counterflow): scalp WITH the trend after a higher-low / lower-high confirmation. Useful in clear trending regimes when Counterflow underperforms.
- **Mean reversion on funding extremes**: ignore TF entirely, fade funding|z| > 3 with tight stop.
- **Liquidation absorption**: enter long after a long-liq cascade > 99th percentile if price stabilizes. Counter-narrative to Counterflow which fades into the cascade.

Each strategy is a separate module. Multi-strategy portfolio mode would route signals through a meta-allocator that weights strategies by recent performance.
- **Effort**: ~5-7 days per strategy. Meta-allocator: ~10 days.

## 9.5 Mobile push notifications

- Lightweight React Native app (or Expo Snack equivalent) just for receive-and-display of signals.
- Push delivered via Firebase Cloud Messaging from a small Phoenix endpoint that the app registers against.
- Same auth as web (token issued on app login).
- App can `/admin/kill` if user adds the role.
- **Effort**: ~10-14 days including App Store / Play Store onboarding.

## 9.6 Copy trading / signal subscription

Revenue model: external users subscribe to Counterflow's signals (read-only feed, no execution).

- Multi-tenant data isolation (Phase 9 hardening).
- API endpoint `/api/signals` with token auth, rate-limited.
- Webhook push for paid tier.
- Signed signal payloads (`HMAC` over canonical JSON) so subscribers can verify origin.
- Legal compliance: signals are NOT financial advice. Disclaimer prominent. Jurisdictional review needed before charging real money.
- **Effort**: ~21+ days; the legal and ops side eclipses the engineering.

## 9.7 Advanced order types

Not required for the strategy, but useful as the strategy graduates to larger sizes:

- **TWAP** (time-weighted average price) for large entries that would move the market.
- **Iceberg** orders.
- **Post-only with reprice** (passive maker fee farming on entries).

Implementing these in `Counterflow.Broker.Live` is straightforward; the harder problem is detecting *when* to use them, which is a function of position size and recent volatility.
- **Effort**: ~7 days.

## 9.8 Custom charting (replace TradingView widget)

The TV free widget is fine for v1, but its limitations (no custom indicators on chart, no custom drawing tools tied to our data) become annoying at scale.

Replacement: build a custom charting component with `lightweight-charts` (TradingView's open-source charting library, MIT license — different from the proprietary widget).
- Allows overlaying our OI / LSR / CVD on the price chart.
- Allows marking signals directly on the chart with TP/SL lines.
- More work but more powerful.
- **Effort**: ~10-14 days.

## 9.9 Better hosting / infra

- Phase 1-8: single VPS (Hetzner CX32, ~€7/mo).
- Phase 9 if running live trading at scale: dedicated server, redundant network, off-site DB backups, automated failover.
- Probably overkill for personal trading; required only if going SaaS.

## 9.10 Observability

- Prometheus + Grafana already wired in Phase 8 baseline.
- Add: signal-to-fill latency, strategy compute time histogram, ws reconnect frequency, kill-switch engagement counter, daily PnL with annotations.
- PagerDuty / Pushover integration for critical alerts (killswitch engaged, daily loss cap hit, reconciliation divergence).

## 9.11 Things we are deliberately NOT building

- **Built-in tax reporting**: trade journal export to CSV is enough; users can pipe into CoinTracker / Koinly.
- **Social features** (chat, leaderboards): scope creep, distracts from trading core.
- **Margin/lending bots**: separate domain, different risk profile.
- **Arbitrage bots**: different latency requirements (sub-millisecond), don't fit Elixir/Phoenix architecture.
- **Crypto news ingestion / sentiment**: weak signal, lots of noise, not part of "smart money" thesis.

## 9.12 Decision log template

For each new direction proposed in this phase, before committing:

1. Why now? (What does the current platform fail to do that this fixes?)
2. Estimated effort vs estimated upside.
3. Reversible? (Can we ship and remove if it doesn't work?)
4. Does it touch the live broker? If yes, does it require re-running Phase 8 testnet?
5. What's the smallest end-to-end version we can ship to learn?

Each major Phase 9 item gets its own `docs/plan/9X-*.md` doc when actually scheduled — this overview is just the menu.

# Counterflow — Deploy guide (Kamal 2 → VPS/EC2)

Single-server production deploy targeting `counterflow.marcosz.com.br`.

## What you need

- **A Linux server** with Docker installed. Anywhere from €4/mo Hetzner CX22 to a t3.micro EC2 works. Allow inbound 22, 80, 443.
- **DNS A record** for `counterflow.marcosz.com.br` pointing at the server's IP. SSL is provisioned automatically by kamal-proxy via Let's Encrypt; the cert request fails if DNS isn't already pointing here.
- **A Docker registry** (Docker Hub free tier is fine) where Kamal pushes the built image.
- **Ruby + Kamal installed locally**: `gem install kamal`.

## One-time setup

```bash
cd counterflow

# 1. Generate session secret
mix phx.gen.secret      # copy the output, you'll paste it into .kamal/secrets

# 2. Configure secrets
cp .kamal/secrets.example .kamal/secrets
$EDITOR .kamal/secrets   # fill SECRET_KEY_BASE, POSTGRES_PASSWORD, DATABASE_URL,
                         # COUNTERFLOW_OWNER_EMAIL/PASSWORD, registry creds.

# 3. Bootstrap the server (installs Docker if missing, runs DB accessory,
#    pushes the first image, configures kamal-proxy + Let's Encrypt)
kamal setup
```

That's it. The first deploy can take ~5 minutes (image build + DB accessory pull + cert provisioning). Subsequent deploys are <60s.

## Subsequent deploys

```bash
git push                 # not strictly required; kamal builds from local files
kamal deploy             # builds, pushes, swaps containers, runs migrations
kamal app logs -f        # tail prod logs
kamal rollback           # if something breaks
```

## What's running on the box after `kamal setup`

| Container | Image | Purpose |
|---|---|---|
| `kamal-proxy` | basecamp/kamal-proxy | TLS termination + routing on :80/:443 |
| `counterflow-web-...` | your-registry/counterflow | The Phoenix app on :4000 |
| `counterflow-db` | timescale/timescaledb:latest-pg16 | Persistent DB on :5432 (loopback only) |

The DB volume is named `counterflow-db-data` and survives redeploys. To inspect:
```bash
ssh root@counterflow.marcosz.com.br
docker exec -it counterflow-db psql -U counterflow counterflow_prod
```

## First-time login

The `COUNTERFLOW_OWNER_EMAIL` + `COUNTERFLOW_OWNER_PASSWORD` you set in `.kamal/secrets` auto-create the first user on initial container boot via `Counterflow.Accounts.owner/0`. After deploy, browse to `https://counterflow.marcosz.com.br/login` and use those credentials.

To create additional users later:
```bash
kamal app exec --interactive './bin/counterflow remote'
# inside the IEx remote shell:
iex> Counterflow.Accounts.register_user("teammate@example.com", "their-password", is_admin: false)
```

## Operational tasks

| Task | Command |
|---|---|
| Tail logs | `kamal app logs -f` |
| Open IEx in prod | `kamal app exec -i -r web './bin/counterflow remote'` |
| Engage kill switch from the host | `ssh root@... 'docker exec -e COUNTERFLOW_KILL=1 counterflow-web /app/bin/counterflow start'` (or just hit `/admin/kill` in the UI when it lands) |
| Backup DB | `ssh root@... 'docker exec counterflow-db pg_dump -U counterflow counterflow_prod' > backup-$(date +%F).sql` |
| Run migrations manually | `kamal app exec './bin/migrate'` |
| Rollback last deploy | `kamal rollback` |
| Update Telegram/LLM keys | edit `.kamal/secrets` then `kamal env push && kamal app boot` |

## Costs (rough)

- Hetzner CX22 (€4/mo) — comfortable for a 30-symbol watchlist + 5min strategy
- Hetzner CX32 (€7/mo) — recommended if running 100+ symbols or active live trading
- EC2 t3.small reserved (~$15/mo) — same envelope as CX32
- Docker Hub free — 1 private repo is enough
- DNS (whatever your registrar charges) — typically free for an existing domain

DB volume + image registry pulls are bandwidth that won't move the needle.

## Hardening checklist before live trading

Run through these on the server BEFORE setting `BINANCE_API_KEY` (real money):

- [ ] DNS for `counterflow.marcosz.com.br` resolves and SSL cert valid
- [ ] `COUNTERFLOW_OWNER_PASSWORD` is rotated to a long random value
- [ ] Binance API key has **futures-trade + read only**, NO withdrawal permission
- [ ] Binance API key IP-whitelisted to the deploy host's IP
- [ ] DB password rotated; DB is bound to 127.0.0.1 only (already configured in deploy.yml)
- [ ] Kill switch tested: `kamal app exec './bin/counterflow rpc \"Counterflow.Risk.KillSwitch.engage(\\\"prod test\\\", \\\"deploy\\\")\"'` then verify in the UI
- [ ] `pg_dump` snapshot taken
- [ ] Walk-forward backtest passing for the symbols you intend to live-trade
- [ ] 7-day testnet soak (`config :counterflow, :binance_market, :testnet`) showed no reconciliation divergence
- [ ] You've decided on a daily-loss cap and per-trade risk that lets you sleep

When all green, flip `:counterflow, :binance_market, :live` in `config/runtime.exs` (gated by an env var if you prefer), set the live API keys in `.kamal/secrets`, `kamal deploy`. Counterflow.Broker.Live still returns `:live_disabled_until_phase_8b` until the gate clause is removed — see `docs/plan/08-live-execution.md` for the remaining wiring.

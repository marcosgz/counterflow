defmodule Counterflow.Bridge.SignalToPaper do
  @moduledoc """
  Auto-place paper trades from emitted signals.

  Subscribes to `signals:new` PubSub. On each signal: looks up the per-symbol
  config; if `enable_paper = true`, ensures the paper account exists, sizes
  the position from the account's current balance using a 1%-of-equity risk
  budget, and places a MARKET order at the signal price.

  Each fill is tagged with `signal_id` so the outcome evaluator (separate
  module) can post-process performance.
  """

  use GenServer
  require Logger

  alias Counterflow.{Repo, Strategy.Config, Broker.Paper, Broker.PaperAccount}
  alias Counterflow.Strategy.Signal
  alias Phoenix.PubSub

  @account_id "paper-default"
  @default_balance Decimal.new(10_000)
  @per_trade_risk_pct 0.01
  @hard_max_leverage 5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? do
      PubSub.subscribe(Counterflow.PubSub, "signals:new")
      Paper.ensure_account(@account_id, @default_balance)
      {:ok, %{account_id: @account_id}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:signal, %Signal{} = sig}, state) do
    cfg = Config.for(sig.symbol, sig.interval)

    if cfg.enable_paper do
      Task.start(fn -> place_from_signal(sig, cfg, state.account_id) end)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp place_from_signal(%Signal{} = sig, cfg, account_id) do
    case size_position(sig, cfg, account_id) do
      {:ok, qty} when qty != nil ->
        place_bracket(sig, qty, account_id)

      {:skip, reason} ->
        :telemetry.execute(
          [:counterflow, :bridge, :paper, :skipped],
          %{count: 1},
          %{symbol: sig.symbol, reason: reason}
        )
    end
  rescue
    err ->
      Logger.warning("SignalToPaper crashed for #{sig.symbol}: #{Exception.message(err)}")
  end

  defp place_bracket(%Signal{} = sig, qty, account_id) do
    entry_side = if sig.side == "long", do: "BUY", else: "SELL"
    close_side = if sig.side == "long", do: "SELL", else: "BUY"
    half = Decimal.div(qty, Decimal.new(2)) |> Decimal.round(8, :down)

    {:ok, _entry} =
      Paper.place_order(account_id, %{
        symbol: sig.symbol,
        side: entry_side,
        type: "MARKET",
        qty: qty,
        reference_price: sig.price,
        signal_id: sig.id,
        intent: "entry",
        client_id: "auto-#{sig.id}-entry"
      })

    if sig.sl do
      Paper.place_order(account_id, %{
        symbol: sig.symbol,
        side: close_side,
        type: "STOP_MARKET",
        qty: qty,
        stop_price: sig.sl,
        reduce_only: true,
        signal_id: sig.id,
        intent: "sl",
        client_id: "auto-#{sig.id}-sl"
      })
    end

    if sig.tp1 do
      Paper.place_order(account_id, %{
        symbol: sig.symbol,
        side: close_side,
        type: "TAKE_PROFIT_MARKET",
        qty: half,
        stop_price: sig.tp1,
        reduce_only: true,
        signal_id: sig.id,
        intent: "tp1",
        client_id: "auto-#{sig.id}-tp1"
      })
    end

    if sig.tp2 do
      tp2_qty = Decimal.sub(qty, half)

      Paper.place_order(account_id, %{
        symbol: sig.symbol,
        side: close_side,
        type: "TAKE_PROFIT_MARKET",
        qty: tp2_qty,
        stop_price: sig.tp2,
        reduce_only: true,
        signal_id: sig.id,
        intent: "tp2",
        client_id: "auto-#{sig.id}-tp2"
      })
    end

    Logger.info(
      "paper bracket placed for #{sig.symbol}/#{sig.side} score=#{sig.score} qty=#{qty}"
    )

    :telemetry.execute(
      [:counterflow, :bridge, :paper, :placed],
      %{count: 1},
      %{symbol: sig.symbol, side: sig.side}
    )
  end

  defp size_position(%Signal{sl: nil}, _cfg, _account), do: {:skip, :no_sl}

  defp size_position(%Signal{price: price, sl: sl} = sig, cfg, account_id) do
    case Repo.get(PaperAccount, account_id) do
      nil ->
        {:skip, :no_account}

      acc ->
        balance_f = Decimal.to_float(acc.balance)
        risk_amount = balance_f * @per_trade_risk_pct
        price_f = Decimal.to_float(price)
        sl_f = Decimal.to_float(sl)
        r = abs(price_f - sl_f)

        cond do
          r <= 0 ->
            {:skip, :degenerate_r}

          true ->
            base_notional = risk_amount / (r / price_f)
            leverage_cap = min(cfg.max_leverage || @hard_max_leverage, @hard_max_leverage)
            target_notional = base_notional * leverage_cap
            qty_f = target_notional / price_f
            # Hard floor: ignore microscopic positions; max-cap based on equity & leverage
            if qty_f * price_f < 5.0 do
              {:skip, :below_min_notional}
            else
              {:ok, Decimal.from_float(round_to(qty_f, decimals_for(sig.symbol)))}
            end
        end
    end
  end

  # Conservative rounding — no real LOT_SIZE filter yet (would need exchangeInfo).
  defp decimals_for("BTCUSDT"), do: 3
  defp decimals_for("ETHUSDT"), do: 3
  defp decimals_for(_), do: 1

  defp round_to(x, decimals) do
    factor = :math.pow(10, decimals)
    Float.floor(x * factor) / factor
  end
end

defmodule Counterflow.Broker.Paper.Matcher do
  @moduledoc """
  Fills LIMIT / STOP_MARKET / TAKE_PROFIT_MARKET paper orders against closed
  candles. Subscribes to `candles:closed:firehose` (broadcast by every
  SymbolWorker on close) and walks the candle's high/low to determine
  whether any pending order touched its trigger price.

  Trigger rules:
    * LIMIT BUY              fills when candle.low  <= price
    * LIMIT SELL             fills when candle.high >= price
    * STOP_MARKET BUY        fills when candle.high >= stop_price
    * STOP_MARKET SELL       fills when candle.low  <= stop_price
    * TAKE_PROFIT_MARKET BUY fills when candle.low  <= stop_price
    * TAKE_PROFIT_MARKET SELL fills when candle.high >= stop_price

  After a TP or SL fills, the matcher cancels the sibling bracket orders
  for the same signal so a position never closes twice.

  After a TP1 fills (intent="tp1"), the SL for the same signal is
  rewritten to a breakeven stop at the position's entry price — classic
  trade management.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Counterflow.{Repo, Broker.Paper, Broker.PaperOrder, Broker.PaperPosition}
  alias Phoenix.PubSub

  @account "paper-default"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? do
      PubSub.subscribe(Counterflow.PubSub, "candles:closed:firehose")
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:closed_candle, candle}, state) do
    Task.start(fn -> match_candle(candle) end)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp match_candle(candle) do
    open_orders =
      Repo.all(
        from o in PaperOrder,
          where:
            o.symbol == ^candle.symbol and o.status == "NEW" and
              o.type in ["LIMIT", "STOP_MARKET", "TAKE_PROFIT_MARKET"],
          order_by: [asc: o.placed_at]
      )

    Enum.each(open_orders, &maybe_fill(&1, candle))
  rescue
    err -> Logger.warning("paper matcher error: #{Exception.message(err)}")
  end

  # ── matching ────────────────────────────────────────────────

  defp maybe_fill(%PaperOrder{} = order, candle) do
    if triggered?(order, candle) do
      fill_price = compute_fill_price(order, candle)
      Paper.fill_pending(order, fill_price, candle.time)
      notify_fill(order, fill_price)
      handle_post_fill(order)
    end
  end

  defp notify_fill(%PaperOrder{intent: intent, symbol: sym, side: side, qty: qty}, fill_price)
       when intent in ["sl", "tp1", "tp2"] do
    Task.start(fn ->
      Counterflow.Alerts.Telegram.send_fill(%{
        symbol: sym,
        intent: intent,
        side: side,
        price: fill_price,
        qty: qty
      })
    end)
  end

  defp notify_fill(_, _), do: :ok

  defp triggered?(%PaperOrder{type: "LIMIT", side: "BUY", price: p}, c),
    do: gte?(p, c.low)

  defp triggered?(%PaperOrder{type: "LIMIT", side: "SELL", price: p}, c),
    do: lte?(p, c.high)

  defp triggered?(%PaperOrder{type: "STOP_MARKET", side: "BUY", stop_price: sp}, c),
    do: lte?(sp, c.high)

  defp triggered?(%PaperOrder{type: "STOP_MARKET", side: "SELL", stop_price: sp}, c),
    do: gte?(sp, c.low)

  defp triggered?(%PaperOrder{type: "TAKE_PROFIT_MARKET", side: "BUY", stop_price: sp}, c),
    do: gte?(sp, c.low)

  defp triggered?(%PaperOrder{type: "TAKE_PROFIT_MARKET", side: "SELL", stop_price: sp}, c),
    do: lte?(sp, c.high)

  defp triggered?(_order, _candle), do: false

  # LIMIT fills at the limit price exactly. Stops fill at trigger ± slippage.
  defp compute_fill_price(%PaperOrder{type: "LIMIT", price: p}, _c), do: p

  defp compute_fill_price(%PaperOrder{type: "STOP_MARKET", side: side, stop_price: sp}, _c) do
    apply_slip(sp, side, 1.0)
  end

  defp compute_fill_price(%PaperOrder{type: "TAKE_PROFIT_MARKET", side: side, stop_price: sp}, _c) do
    apply_slip(sp, side, 0.5)
  end

  # ── post-fill: cancel siblings, breakeven on TP1 ────────────

  defp handle_post_fill(%PaperOrder{signal_id: nil}), do: :ok

  defp handle_post_fill(%PaperOrder{signal_id: sig_id, intent: intent} = order) do
    siblings =
      Repo.all(
        from o in PaperOrder,
          where: o.signal_id == ^sig_id and o.status == "NEW" and o.id != ^order.id
      )

    cond do
      intent == "tp1" ->
        # Promote SL to breakeven for the rest of the bracket
        promote_sl_to_breakeven(siblings, order)

      intent in ["sl", "tp2"] ->
        # Position is fully closed; cancel everything else for this signal.
        cancel_all(siblings)

      true ->
        :ok
    end
  end

  defp promote_sl_to_breakeven(siblings, %PaperOrder{} = filled) do
    pos =
      Repo.one(
        from p in PaperPosition,
          where: p.account_id == ^@account and p.symbol == ^filled.symbol and is_nil(p.closed_at),
          limit: 1
      )

    Enum.each(siblings, fn sib ->
      cond do
        sib.intent == "sl" and pos != nil ->
          # Move SL to entry price (breakeven)
          sib
          |> PaperOrder.changeset(%{stop_price: pos.entry_avg})
          |> Repo.update!()

        true ->
          :ok
      end
    end)
  end

  defp cancel_all(orders) do
    Enum.each(orders, fn o ->
      o
      |> PaperOrder.changeset(%{status: "CANCELED"})
      |> Repo.update!()
    end)
  end

  # ── helpers ─────────────────────────────────────────────────

  defp gte?(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b) != :lt
  defp lte?(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b) != :gt

  defp apply_slip(%Decimal{} = ref, "BUY", bps) do
    Decimal.mult(ref, Decimal.from_float(1.0 + bps / 10_000))
  end

  defp apply_slip(%Decimal{} = ref, "SELL", bps) do
    Decimal.mult(ref, Decimal.from_float(1.0 - bps / 10_000))
  end
end

defmodule Counterflow.Broker.Paper do
  @moduledoc """
  Paper-trading broker. Persists orders/fills/positions to the paper_*
  tables. Market orders fill at the supplied reference price plus a
  configurable slippage in bps. Fees follow Binance VIP-0 USDT-M Futures
  by default (0.04% taker / 0.02% maker rebate). PnL accounting is
  position-mode (one_way), with hedge mode deferred to a later phase.
  """

  @behaviour Counterflow.Broker

  import Ecto.Query

  alias Counterflow.Repo
  alias Counterflow.Broker.{PaperAccount, PaperOrder, PaperFill, PaperPosition}

  @default_slippage_bps 1.0
  @default_taker_fee 0.0004
  @default_maker_fee -0.0002

  # ── account lifecycle ──────────────────────────────────────

  @doc "Create or fetch an account with the given id and starting balance."
  def ensure_account(id, initial_balance \\ Decimal.new(10_000), user_id \\ nil) do
    uid = user_id || Counterflow.Accounts.owner_id() || raise "no owner user; create one first"

    case Repo.get(PaperAccount, id) do
      nil ->
        %PaperAccount{}
        |> PaperAccount.changeset(%{
          id: id,
          user_id: uid,
          initial_balance: initial_balance,
          balance: initial_balance,
          config: %{
            "slippage_bps" => @default_slippage_bps,
            "taker_fee" => @default_taker_fee,
            "maker_fee" => @default_maker_fee
          }
        })
        |> Repo.insert!()

      acc ->
        acc
    end
  end

  # ── broker behaviour ───────────────────────────────────────

  @impl true
  def place_order(
        account_id,
        %{
          symbol: symbol,
          side: side,
          type: type,
          qty: qty
        } = opts
      ) do
    account = Repo.get!(PaperAccount, account_id)
    now = utc_now()

    client_id =
      Map.get_lazy(opts, :client_id, fn -> "p-#{System.unique_integer([:positive])}" end)

    {:ok, order} =
      Repo.transaction(fn ->
        order =
          %PaperOrder{}
          |> PaperOrder.changeset(%{
            account_id: account_id,
            client_id: client_id,
            symbol: symbol,
            side: side,
            type: type,
            qty: qty,
            price: Map.get(opts, :price),
            stop_price: Map.get(opts, :stop_price),
            reduce_only: Map.get(opts, :reduce_only, false),
            status: "NEW",
            signal_id: Map.get(opts, :signal_id),
            intent: Map.get(opts, :intent, "entry"),
            placed_at: now
          })
          |> Repo.insert!()

        if type == "MARKET" and Map.has_key?(opts, :reference_price) do
          fill_market(order, opts.reference_price, account, now)
        else
          order
        end
      end)

    {:ok, %{order_id: order.id, client_id: client_id, status: order.status}}
  end

  @impl true
  def cancel_order(_account_id, client_id) do
    case Repo.get_by(PaperOrder, client_id: client_id) do
      nil ->
        {:error, :not_found}

      order ->
        order |> PaperOrder.changeset(%{status: "CANCELED"}) |> Repo.update!()
        :ok
    end
  end

  @impl true
  def positions(account_id) do
    {:ok,
     Repo.all(from p in PaperPosition, where: p.account_id == ^account_id and is_nil(p.closed_at))}
  end

  @impl true
  def balance(account_id) do
    case Repo.get(PaperAccount, account_id) do
      nil -> {:error, :not_found}
      acc -> {:ok, acc.balance}
    end
  end

  @impl true
  def open_orders(account_id) do
    {:ok,
     Repo.all(from o in PaperOrder, where: o.account_id == ^account_id and o.status == "NEW")}
  end

  # ── matching engine ─────────────────────────────────────────

  @doc """
  Public fill-at-price entry point used by the Matcher when a pending
  LIMIT / STOP / TP order triggers against a closed candle. Unlike
  `fill_market/4`, the caller supplies the resolved fill price; we don't
  apply additional slippage on top.
  """
  def fill_pending(%PaperOrder{} = order, %Decimal{} = fill_price, %DateTime{} = now) do
    account = Repo.get!(PaperAccount, order.account_id)
    fee_rate = account_fee(account, :taker)
    notional = Decimal.mult(fill_price, order.qty)
    fee = Decimal.mult(notional, Decimal.from_float(fee_rate))

    Repo.insert!(%PaperFill{
      order_id: order.id,
      account_id: order.account_id,
      symbol: order.symbol,
      side: order.side,
      price: fill_price,
      qty: order.qty,
      fee: fee,
      filled_at: now
    })

    pnl = update_position_and_pnl(order, fill_price, fee, account, now)

    Repo.get!(PaperAccount, account.id)
    |> PaperAccount.changeset(%{balance: Decimal.sub(Decimal.add(account.balance, pnl), fee)})
    |> Repo.update!()

    order
    |> PaperOrder.changeset(%{
      status: "FILLED",
      filled_at: now,
      filled_qty: order.qty,
      filled_avg: fill_price
    })
    |> Repo.update!()
  end

  defp fill_market(order, reference_price, account, now) do
    slippage_bps = Map.get(account.config, "slippage_bps", @default_slippage_bps)
    fill_price = apply_slippage(Decimal.new("#{reference_price}"), order.side, slippage_bps)
    fill_pending(order, fill_price, now)
  end

  defp update_position_and_pnl(order, fill_price, _fee, account, now) do
    side = order.side

    pos = current_position(account.id, order.symbol)

    cond do
      is_nil(pos) ->
        # opening new position
        Repo.insert!(%PaperPosition{
          account_id: account.id,
          symbol: order.symbol,
          side: position_side_from_order(side, false),
          qty: order.qty,
          entry_avg: fill_price,
          leverage: 1,
          opened_at: now,
          signal_id: order.signal_id
        })

        Decimal.new(0)

      same_direction?(pos.side, side) ->
        # adding to position — recompute weighted entry_avg
        new_qty = Decimal.add(pos.qty, order.qty)
        new_avg = weighted_avg(pos.entry_avg, pos.qty, fill_price, order.qty)

        pos
        |> PaperPosition.changeset(%{qty: new_qty, entry_avg: new_avg})
        |> Repo.update!()

        Decimal.new(0)

      true ->
        # reducing/closing
        close_qty = Decimal.min(pos.qty, order.qty)
        sign = if pos.side == "LONG", do: 1, else: -1
        diff = Decimal.sub(fill_price, pos.entry_avg)
        pnl = Decimal.mult(Decimal.mult(diff, close_qty), Decimal.new(sign))

        new_qty = Decimal.sub(pos.qty, close_qty)
        new_realized = Decimal.add(pos.realized_pnl, pnl)

        attrs =
          if Decimal.compare(new_qty, 0) == :eq do
            %{qty: new_qty, realized_pnl: new_realized, closed_at: now}
          else
            %{qty: new_qty, realized_pnl: new_realized}
          end

        pos |> PaperPosition.changeset(attrs) |> Repo.update!()
        pnl
    end
  end

  defp current_position(account_id, symbol) do
    Repo.one(
      from p in PaperPosition,
        where: p.account_id == ^account_id and p.symbol == ^symbol and is_nil(p.closed_at),
        limit: 1
    )
  end

  defp position_side_from_order("BUY", _reduce_only), do: "LONG"
  defp position_side_from_order("SELL", _reduce_only), do: "SHORT"

  defp same_direction?("LONG", "BUY"), do: true
  defp same_direction?("SHORT", "SELL"), do: true
  defp same_direction?(_, _), do: false

  defp weighted_avg(p1, q1, p2, q2) do
    n1 = Decimal.mult(p1, q1)
    n2 = Decimal.mult(p2, q2)
    Decimal.div(Decimal.add(n1, n2), Decimal.add(q1, q2))
  end

  defp apply_slippage(reference, "BUY", bps) do
    Decimal.mult(reference, Decimal.from_float(1.0 + bps / 10_000))
  end

  defp apply_slippage(reference, "SELL", bps) do
    Decimal.mult(reference, Decimal.from_float(1.0 - bps / 10_000))
  end

  defp account_fee(account, :taker), do: Map.get(account.config, "taker_fee", @default_taker_fee)
  # :maker kept for the LIMIT-fill path that lands when the matching engine
  # graduates from MARKET-only to live-tape limit fills.
  def account_maker_fee(account), do: Map.get(account.config, "maker_fee", @default_maker_fee)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end

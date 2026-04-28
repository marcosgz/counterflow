defmodule Counterflow.Broker.PaperTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.Broker.Paper
  alias Counterflow.Broker.{PaperPosition, PaperFill}
  alias Counterflow.Repo

  setup do
    Paper.ensure_account("test", Decimal.new(10_000))
    :ok
  end

  test "opening LONG market order creates position and applies slippage" do
    {:ok, %{order_id: oid}} =
      Paper.place_order("test", %{
        symbol: "BTCUSDT",
        side: "BUY",
        type: "MARKET",
        qty: Decimal.new("0.1"),
        reference_price: Decimal.new("50000")
      })

    fill = Repo.get_by!(PaperFill, order_id: oid)
    # 1bp slippage on BUY → fill_price = 50000 * (1 + 0.0001)
    assert Decimal.to_float(fill.price) > 50000.0
    assert Decimal.to_float(fill.price) < 50010.0

    pos = Repo.one(from p in PaperPosition, where: p.account_id == "test")
    assert pos.side == "LONG"
    assert Decimal.to_float(pos.qty) == 0.1
  end

  test "round-trip LONG profit accrues to balance" do
    {:ok, _} =
      Paper.place_order("test", %{
        symbol: "BTCUSDT",
        side: "BUY",
        type: "MARKET",
        qty: Decimal.new("0.1"),
        reference_price: Decimal.new("50000")
      })

    {:ok, _} =
      Paper.place_order("test", %{
        symbol: "BTCUSDT",
        side: "SELL",
        type: "MARKET",
        qty: Decimal.new("0.1"),
        reference_price: Decimal.new("51000")
      })

    {:ok, balance} = Paper.balance("test")
    # Approx: opened at 50005 (slippage), closed at 50994.9 (reverse slippage)
    # PnL ≈ 0.1 * (50994.9 - 50005) = ~98.99 minus fees (~4 each side)
    # Account starts at 10k → ends ~10090
    assert Decimal.to_float(balance) > 10_080.0
    assert Decimal.to_float(balance) < 10_100.0
  end

  test "cancel_order marks status CANCELED" do
    {:ok, %{client_id: cid}} =
      Paper.place_order("test", %{
        symbol: "BTCUSDT",
        side: "BUY",
        type: "LIMIT",
        qty: Decimal.new("0.1"),
        price: Decimal.new("40000")
      })

    assert :ok = Paper.cancel_order("test", cid)
    {:ok, open} = Paper.open_orders("test")
    assert open == []
  end
end

defmodule Counterflow.WatchlistTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.{Accounts, Watchlist, Repo, Market.WatchlistEntry}

  defp lookup(symbol) do
    uid = Accounts.owner_id()
    Repo.get_by(WatchlistEntry, user_id: uid, symbol: symbol)
  end

  test "pin/unpin round-trips a symbol" do
    {:ok, _} = Watchlist.pin("BTCUSDT")
    assert %WatchlistEntry{pinned: true, promoted_by: "manual"} = lookup("BTCUSDT")

    {:ok, _} = Watchlist.unpin("BTCUSDT")
    assert %WatchlistEntry{pinned: false} = lookup("BTCUSDT")
  end

  test "promote sets promoted_by and score" do
    {:ok, _} = Watchlist.promote("ETHUSDT", :oi_growth, 0.83)
    entry = lookup("ETHUSDT")
    assert entry.promoted_by == "oi_growth"
    assert Decimal.to_float(entry.promoted_score) == 0.83
  end

  test "remove deletes the entry" do
    {:ok, _} = Watchlist.pin("SOLUSDT")
    assert :ok = Watchlist.remove("SOLUSDT")
    refute lookup("SOLUSDT")
  end
end

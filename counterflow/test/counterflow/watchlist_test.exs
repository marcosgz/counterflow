defmodule Counterflow.WatchlistTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.{Watchlist, Repo, Market.WatchlistEntry}

  test "pin/unpin round-trips a symbol" do
    {:ok, _} = Watchlist.pin("BTCUSDT")
    assert %WatchlistEntry{pinned: true, promoted_by: "manual"} = Repo.get(WatchlistEntry, "BTCUSDT")

    {:ok, _} = Watchlist.unpin("BTCUSDT")
    assert %WatchlistEntry{pinned: false} = Repo.get(WatchlistEntry, "BTCUSDT")
  end

  test "promote sets promoted_by and score" do
    {:ok, _} = Watchlist.promote("ETHUSDT", :oi_growth, 0.83)
    entry = Repo.get(WatchlistEntry, "ETHUSDT")
    assert entry.promoted_by == "oi_growth"
    assert Decimal.to_float(entry.promoted_score) == 0.83
  end

  test "remove deletes the entry" do
    {:ok, _} = Watchlist.pin("SOLUSDT")
    assert :ok = Watchlist.remove("SOLUSDT")
    refute Repo.get(WatchlistEntry, "SOLUSDT")
  end
end

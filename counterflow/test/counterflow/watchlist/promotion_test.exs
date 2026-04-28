defmodule Counterflow.Watchlist.PromotionTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.{Repo, Watchlist, Watchlist.Promotion}
  alias Counterflow.Market.{Liquidation, FundingRate}

  setup do
    {:ok, _} = Watchlist.pin("BTCUSDT")
    :ok
  end

  defp insert_liq(symbol, notional) do
    qty = Decimal.new("0.1")
    price = Decimal.div(Decimal.from_float(notional / 1.0), qty)

    Repo.insert_all(Liquidation, [
      %{
        symbol: symbol,
        time: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        side: "SELL",
        price: price,
        qty: qty
      }
    ])
  end

  defp insert_funding(symbol, rate) do
    Repo.insert_all(FundingRate, [
      %{
        symbol: symbol,
        time: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        funding_rate: Decimal.from_float(rate)
      }
    ])
  end

  test "ranks symbols with high liquidation notional ahead of quiet ones" do
    insert_liq("AAAUSDT", 5_000_000.0)
    insert_liq("BBBUSDT", 50_000.0)
    insert_funding("AAAUSDT", 0.0001)
    insert_funding("BBBUSDT", 0.0001)

    candidates = Promotion.rank_candidates(limit: 10)
    assert [first | _rest] = candidates
    assert first.symbol == "AAAUSDT"
  end

  test "excludes symbols already on the watchlist" do
    insert_liq("BTCUSDT", 10_000_000.0)
    insert_funding("BTCUSDT", 0.005)
    insert_funding("CCCUSDT", 0.005)
    insert_liq("CCCUSDT", 200_000.0)

    candidates = Promotion.rank_candidates(limit: 10)
    refute Enum.any?(candidates, &(&1.symbol == "BTCUSDT"))
    assert Enum.any?(candidates, &(&1.symbol == "CCCUSDT"))
  end

  test "funding extreme alone is enough to qualify" do
    insert_funding("DDDUSDT", 0.005)

    candidates = Promotion.rank_candidates(limit: 10)
    assert Enum.find(candidates, &(&1.symbol == "DDDUSDT")).reason == "funding_extreme"
  end

  test "low-activity symbols below the threshold get score=0 and are excluded" do
    insert_funding("EEEUSDT", 0.00001)
    candidates = Promotion.rank_candidates(limit: 10)
    refute Enum.any?(candidates, &(&1.symbol == "EEEUSDT"))
  end
end

defmodule Counterflow.Broker.Paper.MatcherTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.Broker.{Paper, Paper.Matcher, PaperOrder, PaperFill, PaperPosition}
  alias Counterflow.Repo
  alias Phoenix.PubSub
  import Ecto.Query

  setup do
    Paper.ensure_account("paper-default", Decimal.new(10_000))
    {:ok, _pid} = start_supervised({Matcher, enabled?: true}, restart: :temporary)
    Process.sleep(30)
    :ok
  end

  defp candle(symbol, %{open: o, high: h, low: l, close: c}) do
    %Counterflow.Market.Candle{
      symbol: symbol,
      interval: "1m",
      time: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      open: Decimal.new("#{o}"),
      high: Decimal.new("#{h}"),
      low: Decimal.new("#{l}"),
      close: Decimal.new("#{c}"),
      volume: Decimal.new("0"),
      trades: 0,
      closed: true
    }
  end

  test "STOP_MARKET SELL fills when candle low touches stop" do
    {:ok, %{order_id: _entry_id}} =
      Paper.place_order("paper-default", %{
        symbol: "BTCUSDT",
        side: "BUY",
        type: "MARKET",
        qty: Decimal.new("0.01"),
        reference_price: Decimal.new("50000"),
        signal_id: "sig-1",
        intent: "entry"
      })

    {:ok, %{order_id: sl_id}} =
      Paper.place_order("paper-default", %{
        symbol: "BTCUSDT",
        side: "SELL",
        type: "STOP_MARKET",
        qty: Decimal.new("0.01"),
        stop_price: Decimal.new("49500"),
        reduce_only: true,
        signal_id: "sig-1",
        intent: "sl",
        client_id: "sig-1-sl"
      })

    PubSub.broadcast(Counterflow.PubSub, "candles:closed:firehose",
      {:closed_candle, candle("BTCUSDT", %{open: 50_000, high: 50_100, low: 49_400, close: 49_450})}
    )

    Process.sleep(150)

    sl = Repo.get!(PaperOrder, sl_id)
    assert sl.status == "FILLED"

    fills = Repo.all(from f in PaperFill, where: f.order_id == ^sl_id)
    assert length(fills) == 1
  end

  test "TAKE_PROFIT_MARKET fills + cancels sibling SL when intent=tp2" do
    Paper.place_order("paper-default", %{
      symbol: "BTCUSDT",
      side: "BUY",
      type: "MARKET",
      qty: Decimal.new("0.02"),
      reference_price: Decimal.new("50000"),
      signal_id: "sig-2",
      intent: "entry"
    })

    {:ok, %{order_id: sl_id}} =
      Paper.place_order("paper-default", %{
        symbol: "BTCUSDT",
        side: "SELL",
        type: "STOP_MARKET",
        qty: Decimal.new("0.02"),
        stop_price: Decimal.new("49500"),
        reduce_only: true,
        signal_id: "sig-2",
        intent: "sl",
        client_id: "sig-2-sl"
      })

    {:ok, %{order_id: tp2_id}} =
      Paper.place_order("paper-default", %{
        symbol: "BTCUSDT",
        side: "SELL",
        type: "TAKE_PROFIT_MARKET",
        qty: Decimal.new("0.02"),
        stop_price: Decimal.new("51000"),
        reduce_only: true,
        signal_id: "sig-2",
        intent: "tp2",
        client_id: "sig-2-tp2"
      })

    # Candle prints high above TP2 → TP2 fills
    PubSub.broadcast(Counterflow.PubSub, "candles:closed:firehose",
      {:closed_candle, candle("BTCUSDT", %{open: 50_500, high: 51_200, low: 50_400, close: 51_100})}
    )

    Process.sleep(200)

    assert Repo.get!(PaperOrder, tp2_id).status == "FILLED"
    assert Repo.get!(PaperOrder, sl_id).status == "CANCELED"
  end

  test "TP1 fill rewrites SL stop_price to position entry (breakeven)" do
    Paper.place_order("paper-default", %{
      symbol: "ETHUSDT",
      side: "BUY",
      type: "MARKET",
      qty: Decimal.new("0.10"),
      reference_price: Decimal.new("3000"),
      signal_id: "sig-3",
      intent: "entry"
    })

    {:ok, %{order_id: sl_id}} =
      Paper.place_order("paper-default", %{
        symbol: "ETHUSDT",
        side: "SELL",
        type: "STOP_MARKET",
        qty: Decimal.new("0.10"),
        stop_price: Decimal.new("2950"),
        reduce_only: true,
        signal_id: "sig-3",
        intent: "sl",
        client_id: "sig-3-sl"
      })

    {:ok, %{order_id: tp1_id}} =
      Paper.place_order("paper-default", %{
        symbol: "ETHUSDT",
        side: "SELL",
        type: "TAKE_PROFIT_MARKET",
        qty: Decimal.new("0.05"),
        stop_price: Decimal.new("3030"),
        reduce_only: true,
        signal_id: "sig-3",
        intent: "tp1",
        client_id: "sig-3-tp1"
      })

    PubSub.broadcast(Counterflow.PubSub, "candles:closed:firehose",
      {:closed_candle, candle("ETHUSDT", %{open: 3010, high: 3050, low: 3005, close: 3040})}
    )

    Process.sleep(200)

    assert Repo.get!(PaperOrder, tp1_id).status == "FILLED"
    sl_after = Repo.get!(PaperOrder, sl_id)
    assert sl_after.status == "NEW"
    pos = Repo.one(from p in PaperPosition, where: p.symbol == "ETHUSDT")
    # SL should now equal entry (breakeven)
    assert Decimal.equal?(sl_after.stop_price, pos.entry_avg)
  end
end

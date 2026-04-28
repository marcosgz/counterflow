defmodule Counterflow.Bridge.SignalToPaperTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.{Strategy.Config, Bridge.SignalToPaper, Broker.Paper}
  alias Counterflow.Strategy.Signal
  alias Counterflow.Broker.{PaperFill, PaperPosition}
  alias Phoenix.PubSub
  import Ecto.Query

  setup do
    Paper.ensure_account("paper-default", Decimal.new(10_000))
    Config.upsert("BTCUSDT", %{enable_paper: true})
    {:ok, _pid} = start_supervised({SignalToPaper, enabled?: true}, restart: :temporary)
    Process.sleep(50)
    :ok
  end

  test "places a paper trade for a long signal when enable_paper=true" do
    sig = %Signal{
      id: "test-sig-1",
      symbol: "BTCUSDT",
      interval: "5m",
      side: "long",
      score: Decimal.new("0.7"),
      components: %{},
      price: Decimal.new("50000"),
      leverage: 5,
      sl: Decimal.new("49500"),
      tp1: Decimal.new("50500"),
      tp2: Decimal.new("51000"),
      ttl_minutes: 120,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    PubSub.broadcast(Counterflow.PubSub, "signals:new", {:signal, sig})
    Process.sleep(200)

    fills = Repo.all(from f in PaperFill, where: f.account_id == "paper-default")
    assert length(fills) == 1
    [fill] = fills
    assert fill.side == "BUY"
    assert fill.symbol == "BTCUSDT"

    positions = Repo.all(from p in PaperPosition, where: p.account_id == "paper-default")
    assert length(positions) == 1
    [pos] = positions
    assert pos.side == "LONG"
  end

  test "skips when enable_paper is false" do
    Config.upsert("ETHUSDT", %{enable_paper: false})

    sig = %Signal{
      id: "test-sig-2",
      symbol: "ETHUSDT",
      interval: "5m",
      side: "long",
      score: Decimal.new("0.7"),
      components: %{},
      price: Decimal.new("3000"),
      leverage: 5,
      sl: Decimal.new("2970"),
      tp1: Decimal.new("3030"),
      tp2: Decimal.new("3060"),
      ttl_minutes: 120,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    PubSub.broadcast(Counterflow.PubSub, "signals:new", {:signal, sig})
    Process.sleep(200)

    fills = Repo.all(from f in PaperFill, where: f.symbol == "ETHUSDT")
    assert fills == []
  end
end

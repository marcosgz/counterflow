defmodule Counterflow.Strategy.PipelineTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.{Strategy.Pipeline, Strategy.Cooldown, Watchlist.Manager}
  alias Counterflow.Market.Candle
  alias Phoenix.PubSub

  setup do
    Cooldown.reset()
    Manager.add("BTCUSDT")
    Process.sleep(50)

    {:ok, pipeline} =
      start_supervised(
        {Pipeline, intervals: ["5m"], strategy_opts: [threshold: 0.0], enabled?: true},
        restart: :temporary
      )

    Process.sleep(50)
    {:ok, pipeline: pipeline}
  end

  test "subscribes to candle topics for watchlist symbols", %{pipeline: pid} do
    state = :sys.get_state(pid)
    assert {"BTCUSDT", "5m"} in state.subscribed
  end

  test "ignores in-flight ticks, processes closed candles without crashing", %{pipeline: pid} do
    candle = %Candle{
      symbol: "BTCUSDT",
      interval: "5m",
      time: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      open: Decimal.new("100"),
      high: Decimal.new("100"),
      low: Decimal.new("100"),
      close: Decimal.new("100"),
      volume: Decimal.new("0"),
      trades: 0,
      closed: true
    }

    PubSub.broadcast(Counterflow.PubSub, "candles:BTCUSDT:5m", {:candle, :tick, candle})
    PubSub.broadcast(Counterflow.PubSub, "candles:BTCUSDT:5m", {:candle, :closed, candle})

    Process.sleep(150)
    assert Process.alive?(pid)
  end
end

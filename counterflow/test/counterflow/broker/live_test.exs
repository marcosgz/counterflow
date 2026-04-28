defmodule Counterflow.Broker.LiveTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.Broker.Live
  alias Counterflow.Risk.KillSwitch

  setup do
    KillSwitch.release("test")
    Application.put_env(:counterflow, :live_whitelist, ["BTCUSDT"])
    on_exit(fn -> Application.delete_env(:counterflow, :live_whitelist) end)
    :ok
  end

  test "killswitch engaged blocks all orders" do
    KillSwitch.engage("test", "operator")
    assert {:error, :killswitch} = Live.place_order("acc", %{symbol: "BTCUSDT", side: "long"})
  end

  test "non-whitelisted symbol is rejected" do
    assert {:error, {:not_whitelisted, _}} =
             Live.place_order("acc", %{symbol: "DOGEUSDT", side: "long"})
  end

  test "even with all gates passing, live broker fails closed (Phase 8b not activated)" do
    assert {:error, :live_disabled_until_phase_8b} =
             Live.place_order("acc", %{
               symbol: "BTCUSDT",
               side: "long",
               signal: %{score: 0.8, id: "x"},
               leverage: 3,
               price_local: Decimal.new("50000"),
               price_remote: Decimal.new("50050")
             })
  end

  test "cancel_order also fails closed" do
    assert {:error, :live_disabled_until_phase_8b} = Live.cancel_order("acc", "client-id")
  end
end

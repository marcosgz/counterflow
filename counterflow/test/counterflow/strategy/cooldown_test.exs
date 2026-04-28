defmodule Counterflow.Strategy.CooldownTest do
  use ExUnit.Case, async: false

  alias Counterflow.Strategy.Cooldown

  setup do
    Cooldown.reset()
    :ok
  end

  test "first emit is allowed, second within window is blocked" do
    assert :ok = Cooldown.maybe_emit("BTCUSDT", "long", "5m")
    assert :cooldown = Cooldown.maybe_emit("BTCUSDT", "long", "5m")
  end

  test "different sides for same symbol are independent" do
    assert :ok = Cooldown.maybe_emit("BTCUSDT", "long", "5m")
    assert :ok = Cooldown.maybe_emit("BTCUSDT", "short", "5m")
  end

  test "different symbols are independent" do
    assert :ok = Cooldown.maybe_emit("BTCUSDT", "long", "5m")
    assert :ok = Cooldown.maybe_emit("ETHUSDT", "long", "5m")
  end
end

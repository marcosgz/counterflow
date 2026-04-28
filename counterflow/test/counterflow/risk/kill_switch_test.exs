defmodule Counterflow.Risk.KillSwitchTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.Risk.KillSwitch

  setup do
    KillSwitch.release("test-setup")
    :ok
  end

  test "starts disengaged" do
    assert KillSwitch.disengaged?()
    refute KillSwitch.engaged?()
  end

  test "engage flips to engaged and persists event" do
    :ok = KillSwitch.engage("test reason", "operator")
    assert KillSwitch.engaged?()
  end

  test "release flips back" do
    :ok = KillSwitch.engage("oops", "operator")
    :ok = KillSwitch.release("operator")
    refute KillSwitch.engaged?()
  end
end

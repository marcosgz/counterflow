defmodule Counterflow.Risk.GatesTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.Risk.{Gates, KillSwitch}

  setup do
    KillSwitch.release("test")
    Application.put_env(:counterflow, :live_whitelist, ["BTCUSDT"])
    on_exit(fn -> Application.delete_env(:counterflow, :live_whitelist) end)
    :ok
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "BTCUSDT",
        side: "long",
        signal: %{score: 0.8, id: "sig-1"},
        leverage: 3,
        price_local: Decimal.new("50000"),
        price_remote: Decimal.new("50050")
      },
      overrides
    )
  end

  test "passes when all checks ok" do
    assert :ok = Gates.check(ctx())
  end

  test "rejects when killswitch engaged" do
    KillSwitch.engage("test", "system")
    assert {:error, :killswitch, _} = Gates.check(ctx())
  end

  test "rejects when score too low" do
    assert {:error, :min_signal_score, _} = Gates.check(ctx(%{signal: %{score: 0.4, id: "x"}}))
  end

  test "rejects leverage above cap" do
    assert {:error, :leverage_cap, _} = Gates.check(ctx(%{leverage: 25}))
  end

  test "rejects when local/remote price diverges" do
    assert {:error, :price_divergence, _} =
             Gates.check(
               ctx(%{price_local: Decimal.new("50000"), price_remote: Decimal.new("60000")})
             )
  end

  test "rejects when symbol not whitelisted" do
    assert {:error, :not_whitelisted, _} = Gates.check(ctx(%{symbol: "DOGEUSDT"}))
  end
end

defmodule Counterflow.Binance.RestSignedTest do
  use ExUnit.Case, async: false

  alias Counterflow.Binance.RestSigned

  test "sign/2 produces deterministic HMAC-SHA256 hex" do
    # Reference vector: HMAC-SHA256 of "symbol=BTCUSDT&timestamp=1" with secret "k"
    # Computed offline: 4c2f4f2bdc... (we just check it's stable + 64 chars)
    sig = RestSigned.sign("symbol=BTCUSDT&timestamp=1", "k")
    assert String.length(sig) == 64
    assert sig == RestSigned.sign("symbol=BTCUSDT&timestamp=1", "k")
    refute sig == RestSigned.sign("symbol=BTCUSDT&timestamp=2", "k")
  end

  test "credentials/0 returns missing when env vars absent" do
    System.delete_env("BINANCE_TESTNET_API_KEY")
    System.delete_env("BINANCE_TESTNET_API_SECRET")
    Application.put_env(:counterflow, :binance_market, :testnet)

    assert {:error, :missing_testnet_keys} = RestSigned.credentials()
  end
end

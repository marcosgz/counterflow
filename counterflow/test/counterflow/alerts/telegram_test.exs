defmodule Counterflow.Alerts.TelegramTest do
  use ExUnit.Case, async: false

  alias Counterflow.Alerts.Telegram
  alias Counterflow.Strategy.Signal

  setup do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    Application.put_env(:counterflow, :telegram_base, base)
    Application.put_env(:counterflow, Counterflow.Alerts.Telegram, bot_token: "T", chat_id: "C")

    on_exit(fn ->
      Application.delete_env(:counterflow, :telegram_base)
      Application.delete_env(:counterflow, Counterflow.Alerts.Telegram)
    end)

    {:ok, bypass: bypass}
  end

  test "configured? is true with both env vars" do
    assert Telegram.configured?()
  end

  test "test_message posts to /bot<TOKEN>/sendMessage", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botT/sendMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["chat_id"] == "C"
      assert is_binary(decoded["text"])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok": true, "result": {}}))
    end)

    assert {:ok, %{"ok" => true}} = Telegram.test_message("hello")
  end

  test "send/1 formats a signal and posts it", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botT/sendMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["text"] =~ "BTCUSDT"
      assert decoded["text"] =~ "LONG" or decoded["text"] =~ "long"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok": true, "result": {}}))
    end)

    sig = %Signal{
      id: "sig-x",
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

    assert {:ok, _} = Telegram.send(sig)
  end

  test "send/1 returns :missing_token when not configured" do
    Application.delete_env(:counterflow, Counterflow.Alerts.Telegram)
    System.delete_env("TELEGRAM_BOT_TOKEN")

    sig = %Signal{
      id: "sig-y",
      symbol: "X",
      interval: "5m",
      side: "long",
      score: Decimal.new("0.7"),
      components: %{},
      price: Decimal.new("1"),
      leverage: 1,
      ttl_minutes: 60,
      generated_at: DateTime.utc_now()
    }

    assert {:error, :missing_token} = Telegram.send(sig)
  end
end

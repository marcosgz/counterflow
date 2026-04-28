defmodule Counterflow.Binance.RestTest do
  use ExUnit.Case, async: true

  alias Counterflow.Binance.{Rest, Error}

  setup do
    bypass = Bypass.open()
    Application.put_env(:counterflow, :binance_rest_base, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:counterflow, :binance_rest_base) end)
    {:ok, bypass: bypass}
  end

  test "klines returns ok on 200", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/fapi/v1/klines", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s([[1,"1","2","0.5","1.5","100",2,"150",10,"50","75","x"]]))
    end)

    assert {:ok, [[1, _, _, _, _, _, _, _, _, _, _, _]]} =
             Rest.klines("BTCUSDT", "1m", limit: 1)
  end

  test "klines tags retryable error on 429", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/fapi/v1/klines", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(429, ~s({"code":-1003,"msg":"rate limited"}))
    end)

    assert {:error, %Error{code: -1003, retryable: true}} = Rest.klines("BTCUSDT", "1m")
  end
end

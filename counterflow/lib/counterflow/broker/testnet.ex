defmodule Counterflow.Broker.Testnet do
  @moduledoc """
  Binance USDT-M Futures testnet broker. Uses the same HMAC-signed
  client as the live broker but against testnet.binancefuture.com.

  Activation:
    config :counterflow, :binance_market, :testnet
    config :counterflow, :broker_impl, Counterflow.Broker.Testnet

  Then set BINANCE_TESTNET_API_KEY and BINANCE_TESTNET_API_SECRET in env.

  This is the path the operational checklist (docs/plan/08-live-execution.md)
  walks through before flipping to :live. It exercises every code path
  except the irreversible "real money" step.
  """

  @behaviour Counterflow.Broker

  alias Counterflow.Binance.RestSigned

  @impl true
  def place_order(_account_id, %{symbol: sym, side: side, type: type, qty: qty} = order) do
    params =
      [
        symbol: sym,
        side: side,
        type: type,
        quantity: to_string(qty)
      ]
      |> add_if_present(:price, order[:price])
      |> add_if_present(:stopPrice, order[:stop_price])
      |> add_if_present(:timeInForce, order[:time_in_force] || tif_for(type))
      |> add_if_present(:reduceOnly, order[:reduce_only])
      |> add_if_present(:newClientOrderId, order[:client_id])

    RestSigned.post_signed("/fapi/v1/order", params)
  end

  @impl true
  def cancel_order(_account_id, client_id) do
    case RestSigned.delete_signed("/fapi/v1/order", origClientOrderId: client_id) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  @impl true
  def positions(_account_id) do
    case RestSigned.get_signed("/fapi/v2/positionRisk") do
      {:ok, list} when is_list(list) -> {:ok, list}
      err -> err
    end
  end

  @impl true
  def balance(_account_id) do
    case RestSigned.get_signed("/fapi/v2/balance") do
      {:ok, balances} when is_list(balances) ->
        usdt = Enum.find(balances, fn b -> b["asset"] == "USDT" end)
        if usdt, do: {:ok, Decimal.new(usdt["balance"])}, else: {:ok, Decimal.new(0)}

      err ->
        err
    end
  end

  @impl true
  def open_orders(_account_id) do
    case RestSigned.get_signed("/fapi/v1/openOrders") do
      {:ok, list} when is_list(list) -> {:ok, list}
      err -> err
    end
  end

  defp add_if_present(list, _k, nil), do: list
  defp add_if_present(list, _k, false), do: list
  defp add_if_present(list, k, v), do: [{k, v} | list]

  defp tif_for("LIMIT"), do: "GTC"
  defp tif_for(_), do: nil
end

defmodule Counterflow.Broker do
  @moduledoc """
  Behaviour shared by Paper, Testnet, and Live broker implementations.
  Selecting which impl is loaded happens via Application config:
      config :counterflow, :broker_impl, Counterflow.Broker.Paper
  """

  @type account_id :: String.t()
  @type order :: map()
  @type ack :: map()

  @callback place_order(account_id(), order()) :: {:ok, ack()} | {:error, term()}
  @callback cancel_order(account_id(), String.t()) :: :ok | {:error, term()}
  @callback positions(account_id()) :: {:ok, list()}
  @callback balance(account_id()) :: {:ok, Decimal.t()}
  @callback open_orders(account_id()) :: {:ok, list()}

  def impl, do: Application.get_env(:counterflow, :broker_impl, Counterflow.Broker.Paper)
end

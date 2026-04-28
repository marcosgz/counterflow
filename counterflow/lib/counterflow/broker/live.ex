defmodule Counterflow.Broker.Live do
  @moduledoc """
  Live broker stub. Implements the Counterflow.Broker behaviour but rejects
  all requests unless the killswitch is disengaged AND the symbol is in the
  live_whitelist AND the gates pass.

  Actual REST submission to Binance is intentionally not yet wired — that's
  a deliberate Phase 8b activation step gated on the operational checklist
  in docs/plan/08-live-execution.md. Until then this module guarantees that
  no order can be sent by mistake.
  """

  @behaviour Counterflow.Broker

  alias Counterflow.Risk.{Gates, KillSwitch}

  @impl true
  def place_order(_account_id, %{symbol: sym, side: side} = order) do
    ctx =
      %{symbol: sym, side: side}
      |> Map.merge(Map.take(order, [:signal, :notional, :leverage, :price_local, :price_remote]))

    cond do
      KillSwitch.engaged?() ->
        {:error, :killswitch}

      true ->
        case Gates.check(ctx) do
          :ok ->
            # Phase 8b activation point: replace this with HMAC-signed POST to
            # /fapi/v1/order. Until activated, fail closed.
            {:error, :live_disabled_until_phase_8b}

          {:error, gate, details} ->
            {:error, {gate, details}}
        end
    end
  end

  @impl true
  def cancel_order(_account_id, _client_id), do: {:error, :live_disabled_until_phase_8b}

  @impl true
  def positions(_account_id), do: {:ok, []}

  @impl true
  def balance(_account_id), do: {:ok, Decimal.new(0)}

  @impl true
  def open_orders(_account_id), do: {:ok, []}
end

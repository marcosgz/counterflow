defmodule Counterflow.Binance.WS.UserData do
  @moduledoc """
  User-Data WebSocket. Establishes a listenKey via signed REST, subscribes
  to wss://.../ws/<listenKey> and pumps ACCOUNT_UPDATE / ORDER_TRADE_UPDATE
  / MARGIN_CALL events into PubSub for the live broker to react to.

  Heartbeat: PUT /fapi/v1/listenKey every 30 minutes to keep alive.

  Disabled by default; activated only when :counterflow, :binance_market
  is :testnet or :live AND credentials exist.
  """

  use WebSockex
  require Logger

  alias Counterflow.Binance.RestSigned
  alias Phoenix.PubSub

  def start_link(opts \\ []) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? and credentials_present?() do
      case create_listen_key() do
        {:ok, listen_key} ->
          schedule_keepalive(listen_key)
          state = %{listen_key: listen_key, backoff_ms: 1_000}
          WebSockex.start_link(ws_url(listen_key), __MODULE__, state, name: __MODULE__, async: true)

        {:error, reason} ->
          Logger.warning("UserData WS skipped: #{inspect(reason)}")
          :ignore
      end
    else
      :ignore
    end
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  defp credentials_present? do
    case RestSigned.credentials() do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  defp create_listen_key do
    case RestSigned.post_signed("/fapi/v1/listenKey", []) do
      {:ok, %{"listenKey" => key}} -> {:ok, key}
      err -> err
    end
  end

  defp ws_url(listen_key) do
    case Application.get_env(:counterflow, :binance_market, :testnet) do
      :testnet -> "wss://stream.binancefuture.com/ws/#{listen_key}"
      :live -> "wss://fstream.binance.com/ws/#{listen_key}"
    end
  end

  defp schedule_keepalive(_listen_key) do
    Process.send_after(self(), :keepalive, 30 * 60 * 1_000)
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("UserData WS connected")
    {:ok, %{state | backoff_ms: 1_000}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"e" => event_type} = event} ->
        PubSub.broadcast(Counterflow.PubSub, "user_data:#{event_type}", {:user_data, event})
        :telemetry.execute([:counterflow, :user_data, :event], %{count: 1}, %{type: event_type})

      _ ->
        :ok
    end

    {:ok, state}
  end

  def handle_frame({:ping, _}, state), do: {:reply, {:pong, ""}, state}
  def handle_frame(_other, state), do: {:ok, state}

  @impl true
  def handle_info(:keepalive, state) do
    case RestSigned.post_signed("/fapi/v1/listenKey", []) do
      {:ok, _} ->
        Logger.debug("UserData WS keepalive ok")
        schedule_keepalive(state.listen_key)

      err ->
        Logger.warning("UserData WS keepalive failed: #{inspect(err)}")
    end

    {:ok, state}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("UserData WS disconnected: #{inspect(reason)}, reconnecting")
    Process.sleep(state.backoff_ms)
    {:reconnect, %{state | backoff_ms: min(state.backoff_ms * 2, 60_000)}}
  end
end

defmodule Counterflow.Binance.WS.Liquidations do
  @moduledoc """
  Single ws connection to !forceOrder@arr — all-symbol liquidation firehose.

  Each event is persisted to the `liquidations` hypertable and broadcast to
  the PubSub topic `liquidations:firehose` for live UI consumption.
  """

  use WebSockex
  require Logger

  alias Counterflow.{Repo, Market.Liquidation}
  alias Phoenix.PubSub

  @host "wss://fstream.binance.com"

  def start_link(_opts \\ []) do
    state = %{backoff_ms: 1_000}
    WebSockex.start_link("#{base()}/ws/!forceOrder@arr", __MODULE__, state, name: __MODULE__, async: true, handle_initial_conn_failure: true)
  end

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :permanent, type: :worker}
  end

  defp base, do: Application.get_env(:counterflow, :binance_ws_base, @host)

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("liquidations ws connected")
    {:ok, %{state | backoff_ms: 1_000}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"e" => "forceOrder", "o" => o}} ->
        record = parse(o)

        Repo.insert_all(Liquidation, [record])
        PubSub.broadcast(Counterflow.PubSub, "liquidations:firehose", {:liquidation, record})
        PubSub.broadcast(Counterflow.PubSub, "liquidations:#{record.symbol}", {:liquidation, record})

      _ ->
        :ok
    end

    {:ok, state}
  end

  def handle_frame({:ping, _}, state), do: {:reply, {:pong, ""}, state}
  def handle_frame(_other, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("liquidations ws disconnected: #{inspect(reason)}, reconnecting in #{state.backoff_ms}ms")
    Process.sleep(state.backoff_ms)
    {:reconnect, %{state | backoff_ms: min(state.backoff_ms * 2, 60_000)}}
  end

  defp parse(o) do
    %{
      symbol: o["s"],
      time: DateTime.from_unix!((o["T"] || o["E"]) * 1000, :microsecond),
      side: o["S"],
      price: dec(o["p"] || o["ap"]),
      qty: dec(o["q"] || o["z"]),
      order_type: o["o"],
      status: o["X"]
    }
  end

  defp dec(nil), do: nil
  defp dec(s) when is_binary(s), do: Decimal.new(s)
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(f) when is_float(f), do: Decimal.from_float(f)
end

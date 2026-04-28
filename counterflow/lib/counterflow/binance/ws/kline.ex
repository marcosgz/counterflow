defmodule Counterflow.Binance.WS.Kline do
  @moduledoc """
  WebSocket subscription to Binance USD-M Futures kline stream for one symbol.

  Connects to wss://fstream.binance.com/ws/<sym>@kline_<interval>, parses
  incoming frames, and pushes them into Counterflow.Ingest.SymbolWorker.

  Auto-reconnect with exponential backoff (1s..60s). On reconnect, a gap-fill
  is delegated to the SymbolWorker via REST backfill.
  """

  use WebSockex
  require Logger

  alias Counterflow.Ingest.SymbolWorker

  @host "wss://fstream.binance.com"
  @max_backoff_ms 60_000

  # ── public API ──────────────────────────────────────────────

  def start_link(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    interval = Keyword.fetch!(opts, :interval)
    name = Keyword.get(opts, :name, name(symbol, interval))
    url = build_url(symbol, interval)

    state = %{
      symbol: symbol,
      interval: interval,
      backoff_ms: 1_000
    }

    WebSockex.start_link(url, __MODULE__, state, name: name)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :symbol), Keyword.fetch!(opts, :interval)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  defp name(symbol, interval), do: :"binance_ws_kline_#{symbol}_#{interval}"

  defp build_url(symbol, interval) do
    base = Application.get_env(:counterflow, :binance_ws_base, @host)
    "#{base}/ws/#{String.downcase(symbol)}@kline_#{interval}"
  end

  # ── callbacks ───────────────────────────────────────────────

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("kline ws connected: #{state.symbol}/#{state.interval}")
    :telemetry.execute([:counterflow, :ingest, :ws, :connected], %{count: 1}, %{symbol: state.symbol, interval: state.interval})
    {:ok, %{state | backoff_ms: 1_000}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"e" => "kline"} = event} ->
        SymbolWorker.push(state.symbol, state.interval, event)

      {:ok, _other} ->
        :ok

      {:error, _} ->
        Logger.warning("ws bad json from binance: #{inspect(msg)}")
    end

    {:ok, state}
  end

  def handle_frame({:ping, _}, state), do: {:reply, {:pong, ""}, state}
  def handle_frame(_other, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("kline ws disconnected #{state.symbol}/#{state.interval}: #{inspect(reason)}; reconnecting in #{state.backoff_ms}ms")
    :telemetry.execute([:counterflow, :ingest, :ws, :disconnected], %{count: 1}, %{symbol: state.symbol, interval: state.interval})
    Process.sleep(state.backoff_ms)
    {:reconnect, %{state | backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}}
  end
end

defmodule CounterflowWeb.SmokeLive do
  @moduledoc """
  Phase 1 smoke test: subscribe to a single (symbol, interval) PubSub topic,
  show the last 50 candles in a table, update the last row on each tick.
  """

  use CounterflowWeb, :live_view

  alias Counterflow.Ingest.SymbolWorker
  alias Phoenix.PubSub

  @symbol "BTCUSDT"
  @interval "1m"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe(Counterflow.PubSub, SymbolWorker.topic(@symbol, @interval))

    snapshot =
      case SymbolWorker.snapshot(@symbol, @interval) do
        %{closed: closed, open: open} -> closed |> Enum.take(-50) |> append_open(open)
        _ -> []
      end

    {:ok,
     socket
     |> assign(symbol: @symbol, interval: @interval)
     |> assign(:candles, snapshot)}
  end

  @impl true
  def handle_info({:candle, :closed, candle}, socket) do
    candles =
      socket.assigns.candles
      |> Enum.reject(&(&1.time == candle.time and not &1.closed))
      |> Kernel.++([candle])
      |> Enum.take(-50)

    {:noreply, assign(socket, :candles, candles)}
  end

  def handle_info({:candle, :tick, candle}, socket) do
    candles =
      socket.assigns.candles
      |> Enum.reject(&(&1.time == candle.time and not &1.closed))
      |> Kernel.++([candle])
      |> Enum.take(-50)

    {:noreply, assign(socket, :candles, candles)}
  end

  defp append_open(closed, nil), do: closed
  defp append_open(closed, open), do: closed ++ [open]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-5xl mx-auto">
      <h1 class="text-2xl font-bold mb-2">
        Counterflow — Phase 1 smoke test
      </h1>
      <p class="text-sm text-gray-500 mb-4">
        Listening to {@symbol} {@interval} via Binance Futures WS.
        Candles auto-update; last row is the in-flight (open) candle.
      </p>

      <table class="w-full text-sm font-mono border-collapse">
        <thead class="bg-gray-100 dark:bg-gray-800">
          <tr>
            <th class="text-left p-2">Time (UTC)</th>
            <th class="text-right p-2">Open</th>
            <th class="text-right p-2">High</th>
            <th class="text-right p-2">Low</th>
            <th class="text-right p-2">Close</th>
            <th class="text-right p-2">Volume</th>
            <th class="text-right p-2">Trades</th>
            <th class="text-center p-2">Closed?</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={c <- Enum.reverse(@candles)} class={if c.closed, do: "", else: "bg-yellow-50 dark:bg-yellow-900/20"}>
            <td class="p-2">{c.time |> DateTime.to_iso8601()}</td>
            <td class="p-2 text-right">{c.open}</td>
            <td class="p-2 text-right">{c.high}</td>
            <td class="p-2 text-right">{c.low}</td>
            <td class="p-2 text-right">{c.close}</td>
            <td class="p-2 text-right">{c.volume}</td>
            <td class="p-2 text-right">{c.trades}</td>
            <td class="p-2 text-center">{if c.closed, do: "✓", else: "…"}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end

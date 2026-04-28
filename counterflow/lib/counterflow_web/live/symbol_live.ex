defmodule CounterflowWeb.SymbolLive do
  @moduledoc """
  Phase 5 deep-dive page for a single symbol. Shows recent candles + OI + LSR
  + funding + signals in tables driven by PubSub.
  """

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias Counterflow.{Repo, Ingest.SymbolWorker}
  alias Counterflow.Strategy.Signal
  alias Counterflow.Market.{OpenInterest, LongShortRatio, FundingRate}
  alias Phoenix.PubSub

  @impl true
  def mount(%{"symbol" => symbol}, _session, socket) do
    interval = "1m"

    if connected?(socket) do
      PubSub.subscribe(Counterflow.PubSub, SymbolWorker.topic(symbol, interval))
      PubSub.subscribe(Counterflow.PubSub, "signals:#{symbol}")
      PubSub.subscribe(Counterflow.PubSub, "liquidations:#{symbol}")
    end

    candles = load_candles(symbol, interval)

    socket =
      socket
      |> assign(:symbol, symbol)
      |> assign(:interval, interval)
      |> assign(:candles, candles)
      |> assign(:oi, recent_oi(symbol))
      |> assign(:lsr, recent_lsr(symbol))
      |> assign(:funding, recent_funding(symbol))
      |> assign(:signals, recent_signals(symbol))

    {:ok, socket}
  end

  @impl true
  def handle_info({:candle, kind, candle}, socket) do
    candles =
      socket.assigns.candles
      |> Enum.reject(&(&1.time == candle.time and not &1.closed))
      |> Kernel.++([candle])
      |> Enum.take(-50)

    socket = if kind == :closed, do: socket, else: socket
    {:noreply, assign(socket, :candles, candles)}
  end

  def handle_info({:signal, sig}, socket) do
    {:noreply, assign(socket, :signals, [sig | socket.assigns.signals] |> Enum.take(20))}
  end

  def handle_info({:liquidation, _}, socket), do: {:noreply, socket}

  defp load_candles(symbol, interval) do
    case SymbolWorker.snapshot(symbol, interval) do
      %{closed: closed, open: open} -> Enum.take(closed, -50) ++ List.wrap(open)
      _ -> []
    end
  end

  defp recent_oi(symbol) do
    Repo.all(
      from o in OpenInterest, where: o.symbol == ^symbol, order_by: [desc: o.time], limit: 12
    )
  end

  defp recent_lsr(symbol) do
    Repo.all(
      from l in LongShortRatio,
        where: l.symbol == ^symbol and l.source == "global_account",
        order_by: [desc: l.time],
        limit: 12
    )
  end

  defp recent_funding(symbol) do
    Repo.all(
      from f in FundingRate, where: f.symbol == ^symbol, order_by: [desc: f.time], limit: 5
    )
  end

  defp recent_signals(symbol) do
    Repo.all(
      from s in Signal, where: s.symbol == ^symbol, order_by: [desc: s.generated_at], limit: 20
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto space-y-6">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-bold font-mono">{@symbol}</h1>
        <nav class="text-sm space-x-4">
          <.link navigate={~p"/"} class="underline">Overview</.link>
          <.link navigate={~p"/watchlist"} class="underline">Watchlist</.link>
        </nav>
      </header>

      <section>
        <h2 class="text-lg font-semibold mb-2">Candles {@interval} (last 50)</h2>
        <div class="overflow-x-auto">
          <table class="w-full text-xs font-mono">
            <thead class="bg-gray-100 dark:bg-gray-800">
              <tr>
                <th class="text-left p-1">Time</th>
                <th class="text-right p-1">O</th>
                <th class="text-right p-1">H</th>
                <th class="text-right p-1">L</th>
                <th class="text-right p-1">C</th>
                <th class="text-right p-1">Vol</th>
                <th class="text-right p-1">Trades</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={c <- Enum.reverse(@candles)}
                class={if c.closed, do: "", else: "bg-yellow-50 dark:bg-yellow-900/20"}
              >
                <td class="p-1">{Calendar.strftime(c.time, "%H:%M:%S")}</td>
                <td class="p-1 text-right">{c.open}</td>
                <td class="p-1 text-right">{c.high}</td>
                <td class="p-1 text-right">{c.low}</td>
                <td class="p-1 text-right">{c.close}</td>
                <td class="p-1 text-right">{c.volume}</td>
                <td class="p-1 text-right">{c.trades}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="grid lg:grid-cols-3 gap-6">
        <div>
          <h2 class="text-lg font-semibold mb-2">Open Interest</h2>
          <table class="w-full text-xs font-mono">
            <tr :for={o <- @oi} class="border-b">
              <td>{Calendar.strftime(o.time, "%H:%M")}</td>
              <td class="text-right">{o.open_interest}</td>
            </tr>
          </table>
        </div>

        <div>
          <h2 class="text-lg font-semibold mb-2">Long/Short Ratio (account)</h2>
          <table class="w-full text-xs font-mono">
            <tr :for={l <- @lsr} class="border-b">
              <td>{Calendar.strftime(l.time, "%H:%M")}</td>
              <td class="text-right">{l.ls_ratio}</td>
            </tr>
          </table>
        </div>

        <div>
          <h2 class="text-lg font-semibold mb-2">Funding</h2>
          <table class="w-full text-xs font-mono">
            <tr :for={f <- @funding} class="border-b">
              <td>{Calendar.strftime(f.time, "%H:%M")}</td>
              <td class="text-right">{f.funding_rate}</td>
            </tr>
          </table>
        </div>
      </section>

      <section>
        <h2 class="text-lg font-semibold mb-2">Recent signals on {@symbol}</h2>
        <div class="text-sm font-mono space-y-1">
          <div :for={s <- @signals} class="p-2 border-l-4 border-gray-300">
            <span class="uppercase">{s.side}</span>
            <span>@ {s.price}</span>
            <span>score={s.score}</span>
            <span class="text-gray-500">{Calendar.strftime(s.generated_at, "%H:%M:%S")}</span>
          </div>
          <div :if={@signals == []} class="text-gray-500">No signals yet.</div>
        </div>
      </section>
    </div>
    """
  end
end

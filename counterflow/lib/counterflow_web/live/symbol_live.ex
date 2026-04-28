defmodule CounterflowWeb.SymbolLive do
  @moduledoc """
  Phase 5+ deep-dive page. Renders:
    * an embedded TradingView widget for the price chart
    * Chart.js panels for OI, LSR, funding, CVD-proxy via taker buy/sell, plus
      a recent-signals table.
  All chart datasets are computed server-side and pushed to the JS hooks via
  push_event/3 on each PubSub update.
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
      send(self(), :hydrate_charts)
    end

    candles = load_candles(symbol, interval)

    socket =
      socket
      |> assign(:symbol, symbol)
      |> assign(:interval, interval)
      |> assign(:candles, candles)
      |> assign(:signals, recent_signals(symbol))

    {:ok, socket}
  end

  @impl true
  def handle_info(:hydrate_charts, socket), do: {:noreply, push_chart_data(socket)}

  def handle_info({:candle, _kind, candle}, socket) do
    candles =
      socket.assigns.candles
      |> Enum.reject(&(&1.time == candle.time and not &1.closed))
      |> Kernel.++([candle])
      |> Enum.take(-100)

    socket = assign(socket, :candles, candles)
    socket = if candle.closed, do: push_chart_data(socket), else: socket
    {:noreply, socket}
  end

  def handle_info({:signal, sig}, socket) do
    {:noreply, assign(socket, :signals, [sig | socket.assigns.signals] |> Enum.take(20))}
  end

  def handle_info({:liquidation, _}, socket), do: {:noreply, socket}

  defp push_chart_data(socket) do
    symbol = socket.assigns.symbol

    socket
    |> push_event("chart:update:chart-oi", line_dataset(load_oi(symbol), &Decimal.to_float(&1.open_interest), "Open Interest"))
    |> push_event("chart:update:chart-lsr", line_dataset(load_lsr(symbol), &Decimal.to_float(&1.ls_ratio), "L/S Ratio"))
    |> push_event("chart:update:chart-funding", bar_dataset(load_funding(symbol), &Decimal.to_float(&1.funding_rate), "Funding"))
    |> push_event("chart:update:chart-cvd", cvd_dataset(socket.assigns.candles))
  end

  defp line_dataset(rows, value_fn, label) do
    sorted = Enum.sort_by(rows, & &1.time, DateTime)

    %{
      labels: Enum.map(sorted, &Calendar.strftime(&1.time, "%H:%M")),
      datasets: [
        %{
          label: label,
          data: Enum.map(sorted, value_fn),
          borderColor: "rgb(34,211,238)",
          backgroundColor: "rgba(34,211,238,0.2)",
          borderWidth: 1,
          tension: 0.2,
          fill: true
        }
      ]
    }
  end

  defp bar_dataset(rows, value_fn, label) do
    sorted = Enum.sort_by(rows, & &1.time, DateTime)
    values = Enum.map(sorted, value_fn)

    %{
      labels: Enum.map(sorted, &Calendar.strftime(&1.time, "%H:%M")),
      datasets: [
        %{
          label: label,
          data: values,
          backgroundColor: Enum.map(values, fn v -> if v >= 0, do: "rgba(34,211,238,0.7)", else: "rgba(244,63,94,0.7)" end),
          borderWidth: 0
        }
      ]
    }
  end

  defp cvd_dataset(candles) do
    closed = Enum.filter(candles, & &1.closed)
    sorted = Enum.sort_by(closed, & &1.time, DateTime)

    {labels, deltas} =
      sorted
      |> Enum.map(fn c ->
        buy = Decimal.to_float(c.taker_buy_quote || Decimal.new(0))
        total = Decimal.to_float(c.quote_volume || Decimal.new(0))
        sell = total - buy
        {Calendar.strftime(c.time, "%H:%M"), buy - sell}
      end)
      |> Enum.unzip()

    cumulative = Enum.scan(deltas, 0.0, fn d, acc -> acc + d end)

    %{
      labels: labels,
      datasets: [
        %{
          label: "CVD (cumulative taker buy − sell, quote)",
          data: cumulative,
          borderColor: "rgb(244,114,182)",
          backgroundColor: "rgba(244,114,182,0.15)",
          borderWidth: 1,
          tension: 0.2,
          fill: true
        }
      ]
    }
  end

  defp load_candles(symbol, interval) do
    case SymbolWorker.snapshot(symbol, interval) do
      %{closed: closed, open: open} -> Enum.take(closed, -100) ++ List.wrap(open)
      _ -> []
    end
  end

  defp load_oi(symbol) do
    Repo.all(from o in OpenInterest, where: o.symbol == ^symbol, order_by: [desc: o.time], limit: 30)
  end

  defp load_lsr(symbol) do
    Repo.all(
      from l in LongShortRatio,
        where: l.symbol == ^symbol and l.source == "global_account",
        order_by: [desc: l.time],
        limit: 30
    )
  end

  defp load_funding(symbol) do
    Repo.all(from f in FundingRate, where: f.symbol == ^symbol, order_by: [desc: f.time], limit: 30)
  end

  defp recent_signals(symbol) do
    Repo.all(from s in Signal, where: s.symbol == ^symbol, order_by: [desc: s.generated_at], limit: 20)
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
          <.link navigate={~p"/signals"} class="underline">Signals</.link>
        </nav>
      </header>

      <section>
        <h2 class="text-lg font-semibold mb-2">Price (TradingView)</h2>
        <div
          id={"tv-#{@symbol}"}
          phx-hook="TradingViewWidget"
          phx-update="ignore"
          data-symbol={@symbol}
          data-interval="5"
          class="w-full h-[480px] bg-gray-50 dark:bg-gray-900"
        >
        </div>
      </section>

      <section class="grid lg:grid-cols-2 gap-6">
        <.chart_panel id="chart-oi" title="Open Interest (24h, 5m)" />
        <.chart_panel id="chart-lsr" title="Long/Short Ratio (account, 5m)" />
        <.chart_panel id="chart-funding" title="Funding Rate (recent ticks)" type="bar" />
        <.chart_panel id="chart-cvd" title="CVD proxy (cumulative taker buy − sell)" />
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

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :type, :string, default: "line"

  defp chart_panel(assigns) do
    ~H"""
    <div>
      <h3 class="text-sm font-semibold mb-1 text-gray-700 dark:text-gray-300">{@title}</h3>
      <div class="relative h-48 bg-gray-50 dark:bg-gray-900 p-2 rounded">
        <canvas
          id={@id}
          phx-hook="ChartJSPanel"
          data-chart-type={@type}
          data-initial-data='{"labels":[],"datasets":[]}'
        >
        </canvas>
      </div>
    </div>
    """
  end
end

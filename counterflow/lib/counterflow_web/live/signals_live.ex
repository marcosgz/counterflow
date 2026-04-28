defmodule CounterflowWeb.SignalsLive do
  @moduledoc "Phase 5 signals feed."

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias Counterflow.{Repo, Strategy.Signal}
  alias Phoenix.PubSub

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe(Counterflow.PubSub, "signals:new")

    socket =
      socket
      |> assign(:filter_symbol, "")
      |> stream(:signals, load_signals(""), at: 0, limit: @page_size)

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"symbol" => sym}, socket) do
    sym = String.upcase(sym)

    {:noreply,
     socket
     |> assign(:filter_symbol, sym)
     |> stream(:signals, load_signals(sym), reset: true, limit: @page_size)}
  end

  @impl true
  def handle_info({:signal, sig}, socket) do
    if socket.assigns.filter_symbol == "" or sig.symbol == socket.assigns.filter_symbol do
      {:noreply, stream_insert(socket, :signals, sig, at: 0, limit: @page_size)}
    else
      {:noreply, socket}
    end
  end

  defp load_signals("") do
    Repo.all(from s in Signal, order_by: [desc: s.generated_at], limit: @page_size)
  end

  defp load_signals(sym) do
    Repo.all(
      from s in Signal,
        where: s.symbol == ^sym,
        order_by: [desc: s.generated_at],
        limit: @page_size
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-5xl mx-auto space-y-4">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-bold">Signals</h1>
        <nav class="text-sm space-x-4">
          <.link navigate={~p"/"} class="underline">Overview</.link>
          <.link navigate={~p"/watchlist"} class="underline">Watchlist</.link>
        </nav>
      </header>

      <form phx-change="filter">
        <input
          type="text"
          name="symbol"
          value={@filter_symbol}
          placeholder="filter by symbol e.g. BTCUSDT"
          class="border rounded px-3 py-1 font-mono w-72"
        />
      </form>

      <div id="signals-feed" phx-update="stream" class="space-y-1 text-sm font-mono">
        <div
          :for={{dom_id, s} <- @streams.signals}
          id={dom_id}
          class={["p-3 rounded border-l-4", side_color(s.side)]}
        >
          <div class="flex justify-between">
            <span class="font-bold">
              <.link navigate={~p"/symbol/#{s.symbol}"} class="underline">{s.symbol}</.link>
              <span class="uppercase">{s.side}</span> @ {s.price} ({s.interval})
            </span>
            <span class="text-gray-500">
              {Calendar.strftime(s.generated_at, "%Y-%m-%d %H:%M:%S")}
            </span>
          </div>
          <div class="text-xs text-gray-500">
            score={s.score} · lev={s.leverage}× ·
            sl={s.sl} · tp1={s.tp1} · tp2={s.tp2}
          </div>
          <div class="text-xs">
            <%= for note <- (s.notes || []) do %>
              <span class="inline-block bg-gray-100 dark:bg-gray-800 px-2 py-0.5 mr-1 rounded">
                {note}
              </span>
            <% end %>
          </div>
        </div>
        <div :if={@streams.signals == []} class="text-gray-500">No signals match.</div>
      </div>
    </div>
    """
  end

  defp side_color("long"), do: "border-emerald-500 bg-emerald-50/50 dark:bg-emerald-900/10"
  defp side_color("short"), do: "border-rose-500 bg-rose-50/50 dark:bg-rose-900/10"
  defp side_color(_), do: "border-gray-300"
end

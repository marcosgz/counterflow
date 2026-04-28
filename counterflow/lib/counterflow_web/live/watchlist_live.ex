defmodule CounterflowWeb.WatchlistLive do
  @moduledoc "Phase 5 watchlist management — pin/unpin/add/remove."

  use CounterflowWeb, :live_view

  alias Counterflow.{Watchlist, Watchlist.Manager}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, watchlist: Watchlist.all(), new_symbol: "")}
  end

  @impl true
  def handle_event("pin", %{"symbol" => s}, socket) do
    {:ok, _} = Watchlist.pin(s)
    {:noreply, assign(socket, watchlist: Watchlist.all())}
  end

  def handle_event("unpin", %{"symbol" => s}, socket) do
    {:ok, _} = Watchlist.unpin(s)
    {:noreply, assign(socket, watchlist: Watchlist.all())}
  end

  def handle_event("add", %{"symbol" => s}, socket) do
    s = String.upcase(s)

    if String.length(s) > 0 do
      Manager.add(s)
    end

    {:noreply, assign(socket, watchlist: Watchlist.all(), new_symbol: "")}
  end

  def handle_event("drop", %{"symbol" => s}, socket) do
    Manager.drop(s)
    {:noreply, assign(socket, watchlist: Watchlist.all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-4xl mx-auto space-y-6">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-bold">Watchlist</h1>
        <nav class="text-sm space-x-4">
          <.link navigate={~p"/"} class="underline">Overview</.link>
          <.link navigate={~p"/signals"} class="underline">Signals</.link>
        </nav>
      </header>

      <form phx-submit="add" class="flex gap-2">
        <input
          type="text"
          name="symbol"
          placeholder="BTCUSDT"
          value={@new_symbol}
          class="border rounded px-3 py-1 font-mono"
        />
        <button type="submit" class="px-4 py-1 bg-emerald-600 text-white rounded">
          Add
        </button>
      </form>

      <table class="w-full text-sm font-mono">
        <thead class="bg-gray-100 dark:bg-gray-800">
          <tr>
            <th class="text-left p-2">Symbol</th>
            <th class="text-left p-2">Pinned</th>
            <th class="text-left p-2">Promoted by</th>
            <th class="text-left p-2">Added</th>
            <th class="p-2">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={w <- @watchlist} class="border-t">
            <td class="p-2">
              <.link navigate={~p"/symbol/#{w.symbol}"} class="underline">{w.symbol}</.link>
            </td>
            <td class="p-2">{if w.pinned, do: "⭐", else: ""}</td>
            <td class="p-2">{w.promoted_by || "-"}</td>
            <td class="p-2">{Calendar.strftime(w.added_at, "%Y-%m-%d %H:%M")}</td>
            <td class="p-2 space-x-2">
              <button
                :if={!w.pinned}
                phx-click="pin"
                phx-value-symbol={w.symbol}
                class="text-yellow-600 hover:underline"
              >
                Pin
              </button>
              <button
                :if={w.pinned}
                phx-click="unpin"
                phx-value-symbol={w.symbol}
                class="text-gray-600 hover:underline"
              >
                Unpin
              </button>
              <button
                phx-click="drop"
                phx-value-symbol={w.symbol}
                data-confirm={"Remove #{w.symbol}?"}
                class="text-rose-600 hover:underline"
              >
                Remove
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end

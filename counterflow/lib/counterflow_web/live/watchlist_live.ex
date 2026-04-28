defmodule CounterflowWeb.WatchlistLive do
  @moduledoc "Trader-grade watchlist management with dense table layout."

  use CounterflowWeb, :live_view

  alias CounterflowWeb.Layouts
  alias Counterflow.{Watchlist, Watchlist.Manager}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/watchlist")
     |> assign(:watchlist, Watchlist.all())
     |> assign(:new_symbol, "")}
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
    if String.length(s) > 0, do: Manager.add(s)
    {:noreply, assign(socket, watchlist: Watchlist.all(), new_symbol: "")}
  end

  def handle_event("drop", %{"symbol" => s}, socket) do
    Manager.drop(s)
    {:noreply, assign(socket, watchlist: Watchlist.all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">WATCHLIST</h1>
          <span class="cf-pill muted">{length(@watchlist)} symbols</span>
        </header>

        <div class="cf-panel cf-panel-flush">
          <div class="cf-panel-head">
            <span class="title"><span class="marker"></span>Add Symbol</span>
            <span class="cf-pill muted">USDT-M futures</span>
          </div>
          <form phx-submit="add" class="cf-panel-body flex gap-2">
            <input
              type="text"
              name="symbol"
              placeholder="BTCUSDT"
              value={@new_symbol}
              class="cf-input grow"
              autocomplete="off"
            />
            <button type="submit" class="cf-btn primary">Add Symbol</button>
          </form>
        </div>

        <div class="cf-panel cf-panel-flush">
          <table class="cf-table">
            <thead>
              <tr>
                <th>Symbol</th>
                <th>Pinned</th>
                <th>Promoted by</th>
                <th>Added</th>
                <th class="num">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={w <- @watchlist}>
                <td>
                  <a href={~p"/symbol/#{w.symbol}"} style="color: var(--ink); font-weight: 600;">{w.symbol}</a>
                </td>
                <td>
                  <span :if={w.pinned} class="cf-pill warn">PINNED</span>
                  <span :if={!w.pinned} style="color: var(--ink-3);">—</span>
                </td>
                <td>
                  <span class="cf-pill muted">{w.promoted_by || "auto"}</span>
                </td>
                <td style="color: var(--ink-3);">{Calendar.strftime(w.added_at, "%Y-%m-%d %H:%M")}</td>
                <td class="num">
                  <div class="flex gap-2 justify-end">
                    <button :if={!w.pinned} phx-click="pin" phx-value-symbol={w.symbol} class="cf-btn">Pin</button>
                    <button :if={w.pinned} phx-click="unpin" phx-value-symbol={w.symbol} class="cf-btn">Unpin</button>
                    <a href={~p"/settings/#{w.symbol}"} class="cf-btn">Tune</a>
                    <button phx-click="drop" phx-value-symbol={w.symbol}
                            data-confirm={"Remove " <> w.symbol <> "?"}
                            class="cf-btn danger">Remove</button>
                  </div>
                </td>
              </tr>
              <tr :if={@watchlist == []}>
                <td colspan="5" class="text-center py-6" style="color: var(--ink-3);">
                  No symbols yet — add one above.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.shell>
    """
  end
end

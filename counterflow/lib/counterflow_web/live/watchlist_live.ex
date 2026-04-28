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
     |> assign(:new_symbol, "")
     |> assign_candidates()
     |> assign(:auto_promote_enabled?, Application.get_env(:counterflow, :auto_promote_enabled?, true))
     |> assign(:rebalance_running?, false)}
  end

  defp assign_candidates(socket) do
    candidates =
      try do
        Counterflow.Watchlist.Promotion.rank_candidates(limit: 12)
      rescue
        _ -> []
      end

    assign(socket, :candidates, candidates)
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
    {:noreply, socket |> assign(:watchlist, Watchlist.all()) |> assign_candidates()}
  end

  def handle_event("toggle_auto_promote", _params, socket) do
    new_state = !socket.assigns.auto_promote_enabled?
    Application.put_env(:counterflow, :auto_promote_enabled?, new_state)
    {:noreply, assign(socket, :auto_promote_enabled?, new_state)}
  end

  def handle_event("rebalance_now", _params, socket) do
    parent = self()

    Task.start(fn ->
      try do
        Counterflow.Watchlist.Promoter.rebalance_now()
      after
        send(parent, :rebalance_done)
      end
    end)

    {:noreply,
     socket
     |> assign(:rebalance_running?, true)
     |> put_flash(:info, "Rebalance running…")}
  end

  def handle_event("promote", %{"symbol" => sym}, socket) do
    Manager.add(sym)
    Watchlist.promote(sym, "manual_from_candidates", nil)

    {:noreply,
     socket
     |> assign(:watchlist, Watchlist.all())
     |> assign_candidates()}
  end

  @impl true
  def handle_info(:rebalance_done, socket) do
    {:noreply,
     socket
     |> assign(:rebalance_running?, false)
     |> assign(:watchlist, Watchlist.all())
     |> assign_candidates()
     |> put_flash(:info, "Rebalance complete.")}
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

        <%!-- Auto-promotion control + candidates --%>
        <div class="cf-panel cf-panel-flush">
          <div class="cf-panel-head">
            <span class="title"><span class="marker warn"></span>Auto-promotion</span>
            <span class="flex items-center gap-2">
              <span class={"cf-pill " <> if(@auto_promote_enabled?, do: "", else: "muted")}
                    style={if(@auto_promote_enabled?, do: "background: var(--long-bg); color: var(--long);", else: "")}>
                {if @auto_promote_enabled?, do: "ENABLED", else: "DISABLED"}
              </span>
              <button phx-click="toggle_auto_promote" class="cf-btn">
                {if @auto_promote_enabled?, do: "Disable", else: "Enable"}
              </button>
              <button phx-click="rebalance_now" class="cf-btn primary" disabled={@rebalance_running?}>
                <%= if @rebalance_running?, do: "Running…", else: "Rebalance now" %>
              </button>
            </span>
          </div>
          <div class="cf-panel-body">
            <p class="mono" style="font-size: 11px; color: var(--ink-3); line-height: 1.6;">
              Top non-watchlist symbols ranked by 1h liquidation notional and current funding extreme.
              Auto-rebalance runs every 5 min when enabled; pinned symbols are never demoted.
            </p>
          </div>
          <table class="cf-table" :if={@candidates != []}>
            <thead>
              <tr>
                <th>Candidate</th>
                <th class="num">Score</th>
                <th>Reason</th>
                <th class="num">Liq 1h ($)</th>
                <th class="num">Funding</th>
                <th class="num">Action</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @candidates}>
                <td>{c.symbol}</td>
                <td class="num">{Float.round(c.score, 3)}</td>
                <td><span class="cf-pill muted">{c.reason}</span></td>
                <td class="num">{format_money(c.liq_notional_1h)}</td>
                <td class="num" style={funding_color(c.funding_rate)}>
                  {format_funding(c.funding_rate)}
                </td>
                <td class="num">
                  <button phx-click="promote" phx-value-symbol={c.symbol} class="cf-btn">Promote</button>
                </td>
              </tr>
            </tbody>
          </table>
          <div :if={@candidates == []} class="cf-panel-body text-center" style="color: var(--ink-3); font-size: 11px;">
            No candidates above the activity threshold right now.
          </div>
        </div>

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

  # ── view helpers ────────────────────────────────────────────

  defp format_money(n) when is_number(n) do
    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 2)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 1)}K"
      true -> "#{Float.round(n, 0)}"
    end
  end

  defp format_money(_), do: "—"

  defp format_funding(rate) when is_number(rate) do
    "#{Float.round(rate * 100, 4)}%"
  end

  defp format_funding(_), do: "—"

  defp funding_color(rate) when is_number(rate) and rate > 0.001, do: "color: var(--short);"
  defp funding_color(rate) when is_number(rate) and rate < -0.001, do: "color: var(--long);"
  defp funding_color(_), do: "color: var(--ink-3);"
end

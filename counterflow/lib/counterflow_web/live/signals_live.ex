defmodule CounterflowWeb.SignalsLive do
  @moduledoc "Trader-grade signals feed with filter + outcome readout."

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias CounterflowWeb.Layouts
  alias Counterflow.{Repo, Strategy.Signal}
  alias Phoenix.PubSub

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe(Counterflow.PubSub, "signals:new")

    {:ok,
     socket
     |> assign(:current_path, "/signals")
     |> assign(:filter_symbol, "")
     |> assign(:filter_side, "")
     |> stream(:signals, load_signals("", ""), at: 0, limit: @page_size)}
  end

  @impl true
  def handle_event("filter", %{"symbol" => sym} = params, socket) do
    sym = String.upcase(sym)
    side = Map.get(params, "side", "")

    {:noreply,
     socket
     |> assign(:filter_symbol, sym)
     |> assign(:filter_side, side)
     |> stream(:signals, load_signals(sym, side), reset: true, limit: @page_size)}
  end

  @impl true
  def handle_info({:signal, sig}, socket) do
    visible? =
      (socket.assigns.filter_symbol == "" or sig.symbol == socket.assigns.filter_symbol) and
        (socket.assigns.filter_side == "" or sig.side == socket.assigns.filter_side)

    if visible? do
      {:noreply, stream_insert(socket, :signals, sig, at: 0, limit: @page_size)}
    else
      {:noreply, socket}
    end
  end

  defp load_signals(sym, side) do
    Repo.all(
      from s in Signal,
        where: ^build_filters(sym, side),
        order_by: [desc: s.generated_at],
        limit: @page_size
    )
  end

  defp build_filters(sym, side) do
    base = true

    base
    |> maybe_filter_symbol(sym)
    |> maybe_filter_side(side)
  end

  defp maybe_filter_symbol(q, ""), do: q
  defp maybe_filter_symbol(_q, sym), do: dynamic([s], s.symbol == ^sym)
  defp maybe_filter_side(q, ""), do: q

  defp maybe_filter_side(q, side) do
    case q do
      true -> dynamic([s], s.side == ^side)
      existing -> dynamic([s], ^existing and s.side == ^side)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">SIGNALS</h1>
          <span class="cf-pill muted">live</span>
        </header>

        <form phx-change="filter" class="flex gap-2 items-center">
          <input
            type="text"
            name="symbol"
            value={@filter_symbol}
            placeholder="filter symbol e.g. BTCUSDT"
            class="cf-input"
            autocomplete="off"
          />
          <select name="side" class="cf-select">
            <option value="" selected={@filter_side == ""}>any side</option>
            <option value="long" selected={@filter_side == "long"}>long</option>
            <option value="short" selected={@filter_side == "short"}>short</option>
          </select>
        </form>

        <div id="signals-feed" phx-update="stream" class="space-y-2">
          <div :for={{dom_id, s} <- @streams.signals} id={dom_id} class="cf-panel">
            <div class="cf-panel-body" style="padding: 12px;">
              <div class="flex items-center justify-between flex-wrap gap-2">
                <div class="flex items-center gap-3 mono">
                  <span class="cf-pill" style={side_pill_style(s.side)}>{String.upcase(s.side)}</span>
                  <a href={~p"/symbol/#{s.symbol}"} style="color: var(--ink); font-weight: 700; font-size: 13px;">{s.symbol}</a>
                  <span style="color: var(--ink-3); font-size: 11px;">{s.interval}</span>
                </div>
                <div class="mono" style="color: var(--ink-3); font-size: 11px;">
                  {Calendar.strftime(s.generated_at, "%Y-%m-%d %H:%M:%S")} UTC
                </div>
              </div>

              <div class="grid grid-cols-2 sm:grid-cols-5 gap-3 mt-3 mono" style="font-size: 11px;">
                <div>
                  <div style="font-size: 9px; letter-spacing: 0.12em; color: var(--ink-3); text-transform: uppercase;">price</div>
                  <div style="color: var(--ink); font-size: 13px;">{s.price}</div>
                </div>
                <div>
                  <div style="font-size: 9px; letter-spacing: 0.12em; color: var(--ink-3); text-transform: uppercase;">score</div>
                  <div style="color: var(--ink); font-size: 13px;">{format_score(s.score)}</div>
                </div>
                <div>
                  <div style="font-size: 9px; letter-spacing: 0.12em; color: var(--ink-3); text-transform: uppercase;">leverage</div>
                  <div style="color: var(--ink); font-size: 13px;">{s.leverage}×</div>
                </div>
                <div>
                  <div style="font-size: 9px; letter-spacing: 0.12em; color: var(--ink-3); text-transform: uppercase;">SL → TP1 → TP2</div>
                  <div style="color: var(--ink-2); font-size: 11px;">
                    <span style="color: var(--short);">{s.sl}</span> →
                    <span style="color: var(--long);">{s.tp1}</span> →
                    <span style="color: var(--long);">{s.tp2}</span>
                  </div>
                </div>
                <div>
                  <div style="font-size: 9px; letter-spacing: 0.12em; color: var(--ink-3); text-transform: uppercase;">outcome</div>
                  <div>{outcome_pill(s.outcome)}</div>
                </div>
              </div>

              <div :if={(s.notes || []) != []} class="mt-2 flex gap-1 flex-wrap">
                <span :for={note <- s.notes} class="cf-pill muted">{note}</span>
              </div>
            </div>
          </div>
          <div :if={Enum.empty?(@streams.signals.inserts)} class="cf-panel">
            <div class="cf-panel-body text-center py-8" style="color: var(--ink-3);">
              No signals match.
            </div>
          </div>
        </div>
      </div>
    </Layouts.shell>
    """
  end

  defp format_score(nil), do: "—"
  defp format_score(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_score(n), do: to_string(n)

  defp side_pill_style("long"), do: "background: var(--long-bg); color: var(--long);"
  defp side_pill_style("short"), do: "background: var(--short-bg); color: var(--short);"
  defp side_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp outcome_pill(nil), do: Phoenix.HTML.raw(~S|<span class="cf-pill muted">PENDING</span>|)

  defp outcome_pill(%{"hit_tp2" => true}),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill" style="background: var(--long-bg); color: var(--long);">TP2 · +2R</span>|)

  defp outcome_pill(%{"hit_tp1" => true}),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill" style="background: var(--long-bg); color: var(--long);">TP1 · +1R</span>|)

  defp outcome_pill(%{"hit_sl" => true}),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill" style="background: var(--short-bg); color: var(--short);">SL · −1R</span>|)

  defp outcome_pill(_),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill muted">EXPIRED</span>|)
end

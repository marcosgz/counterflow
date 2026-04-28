defmodule CounterflowWeb.OverviewLive do
  @moduledoc """
  Trader-grade overview: KPI strip, watchlist heatmap, signal feed,
  liquidations firehose. All sections live-update via PubSub.
  """

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias CounterflowWeb.Layouts
  alias Counterflow.{Repo, Watchlist}
  alias Counterflow.Strategy.Signal
  alias Counterflow.Market.{Liquidation, FundingRate, WatchlistEntry}
  alias Phoenix.PubSub

  @recent_signals 18
  @recent_liqs 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(Counterflow.PubSub, "signals:new")
      PubSub.subscribe(Counterflow.PubSub, "liquidations:firehose")
    end

    {:ok,
     socket
     |> assign(:current_path, "/")
     |> assign(:watchlist, Watchlist.all())
     |> assign(:funding_top, top_funding(:positive))
     |> assign(:funding_bottom, top_funding(:negative))
     |> assign(:kpis, kpi_snapshot())
     |> stream(:signals, recent_signals(), at: 0, limit: @recent_signals)
     |> stream(:liquidations, recent_liquidations(), at: 0, limit: @recent_liqs)}
  end

  @impl true
  def handle_info({:signal, %Signal{} = sig}, socket) do
    {:noreply,
     socket
     |> stream_insert(:signals, sig, at: 0, limit: @recent_signals)
     |> assign(:kpis, kpi_snapshot())}
  end

  def handle_info({:liquidation, liq}, socket) do
    liq = Map.put_new(liq, :id, "liq-#{System.unique_integer([:positive])}")
    {:noreply, stream_insert(socket, :liquidations, liq, at: 0, limit: @recent_liqs)}
  end

  defp recent_signals do
    Repo.all(from s in Signal, order_by: [desc: s.generated_at], limit: @recent_signals)
  end

  defp recent_liquidations do
    Repo.all(from l in Liquidation, order_by: [desc: l.time], limit: @recent_liqs)
    |> Enum.with_index()
    |> Enum.map(fn {l, i} ->
      Map.put(l, :id, "liq-#{DateTime.to_unix(l.time, :microsecond)}-#{i}")
    end)
  end

  defp top_funding(:positive) do
    Repo.all(
      from f in FundingRate,
        where: f.time > ago(2, "minute"),
        order_by: [desc: f.funding_rate],
        limit: 6
    )
  end

  defp top_funding(:negative) do
    Repo.all(
      from f in FundingRate,
        where: f.time > ago(2, "minute"),
        order_by: [asc: f.funding_rate],
        limit: 6
    )
  end

  defp kpi_snapshot do
    today = DateTime.utc_now() |> DateTime.to_date()
    today_start = DateTime.new!(today, ~T[00:00:00.000000], "Etc/UTC")
    day_ago = DateTime.add(DateTime.utc_now(), -86_400, :second)
    hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    %{
      signals_24h: Repo.aggregate(from(s in Signal, where: s.generated_at > ^day_ago), :count),
      signals_today: Repo.aggregate(from(s in Signal, where: s.generated_at >= ^today_start), :count),
      liquidations_1h: Repo.aggregate(from(l in Liquidation, where: l.time > ^hour_ago), :count),
      symbols_tracked: Repo.aggregate(from(w in WatchlistEntry), :count)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 space-y-6 max-w-[1600px] mx-auto">
        <section class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div class="cf-kpi long">
            <div class="cf-kpi-label">Signals · 24h</div>
            <div class="cf-kpi-value">{@kpis.signals_24h}</div>
            <div class="cf-kpi-sub">{@kpis.signals_today} today</div>
          </div>
          <div class="cf-kpi warn">
            <div class="cf-kpi-label">Liquidations · 1h</div>
            <div class="cf-kpi-value">{@kpis.liquidations_1h}</div>
            <div class="cf-kpi-sub">firehose</div>
          </div>
          <div class="cf-kpi">
            <div class="cf-kpi-label">Symbols Tracked</div>
            <div class="cf-kpi-value">{@kpis.symbols_tracked}</div>
            <div class="cf-kpi-sub">watchlist</div>
          </div>
          <div class="cf-kpi short">
            <div class="cf-kpi-label">Strategy</div>
            <div class="cf-kpi-value mono" style="font-size: 14px;">COUNTERFLOW</div>
            <div class="cf-kpi-sub">v0.1 · live</div>
          </div>
        </section>

        <section class="grid grid-cols-1 lg:grid-cols-3 gap-3">
          <div class="cf-panel cf-panel-flush col-span-1 lg:col-span-2">
            <div class="cf-panel-head">
              <span class="title"><span class="marker"></span>Watchlist</span>
              <a href="/watchlist" class="cf-pill muted">manage →</a>
            </div>
            <div class="cf-panel-body">
              <div class="grid grid-cols-3 sm:grid-cols-4 lg:grid-cols-6 gap-2">
                <a :for={w <- @watchlist} class="cf-heat" data-trend={if(w.pinned, do: "up", else: "")}
                   href={~p"/symbol/#{w.symbol}"}>
                  <div class="sym">{w.symbol}</div>
                  <div class="pct">{w.promoted_by || "manual"}</div>
                </a>
              </div>
              <div :if={@watchlist == []} class="text-center py-8" style="color: var(--ink-3);">
                No symbols watched yet · <a href="/watchlist" style="color: var(--ink); text-decoration: underline;">add one</a>
              </div>
            </div>
          </div>

          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker warn"></span>Funding Extremes</span>
              <span class="cf-pill muted">8h cycle</span>
            </div>
            <div class="cf-panel-body" style="padding: 0;">
              <table class="cf-table">
                <thead>
                  <tr><th>Symbol</th><th class="num">Rate</th><th class="num">Mark</th></tr>
                </thead>
                <tbody>
                  <tr :for={f <- @funding_top}>
                    <td><a href={~p"/symbol/#{f.symbol}"} style="color: var(--ink);">{f.symbol}</a></td>
                    <td class="num" style={"color: " <> rate_color(f.funding_rate)}>
                      {format_rate(f.funding_rate)}
                    </td>
                    <td class="num" style="color: var(--ink-3);">{f.mark_price}</td>
                  </tr>
                  <tr :if={@funding_top != [] and @funding_bottom != []}>
                    <td colspan="3" style="border-top: 2px solid var(--line-2); padding: 4px 12px; color: var(--ink-mute); font-size: 9px; text-align: center; letter-spacing: 0.2em;">··· SHORTS PAYING ···</td>
                  </tr>
                  <tr :for={f <- @funding_bottom}>
                    <td><a href={~p"/symbol/#{f.symbol}"} style="color: var(--ink);">{f.symbol}</a></td>
                    <td class="num" style={"color: " <> rate_color(f.funding_rate)}>
                      {format_rate(f.funding_rate)}
                    </td>
                    <td class="num" style="color: var(--ink-3);">{f.mark_price}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <section class="grid grid-cols-1 lg:grid-cols-2 gap-3">
          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker"></span>Live Signals</span>
              <a href="/signals" class="cf-pill muted">all →</a>
            </div>
            <div id="signals-stream" phx-update="stream" class="cf-panel-body" style="padding: 0; max-height: 480px; overflow-y: auto;">
              <div :for={{dom_id, sig} <- @streams.signals} id={dom_id}
                   class="grid grid-cols-12 gap-2 px-3 py-2 mono" style="border-bottom: 1px solid var(--line); font-size: 11px;">
                <span class="col-span-2 cf-pill" style={side_pill_style(sig.side)}>{String.upcase(sig.side)}</span>
                <a class="col-span-3" href={~p"/symbol/#{sig.symbol}"} style="color: var(--ink); font-weight: 600;">{sig.symbol}</a>
                <span class="col-span-2 num" style="color: var(--ink-2);">{sig.price}</span>
                <span class="col-span-2 num" style="color: var(--ink-3);">{format_score(sig.score)}</span>
                <span class="col-span-3 num" style="color: var(--ink-3);">{Calendar.strftime(sig.generated_at, "%H:%M:%S")}</span>
              </div>
              <div class="px-3 py-6 text-center" style="color: var(--ink-3);">
                Awaiting next candle close ·
                <span class="mono" style="color: var(--ink-mute);">strategy live</span>
              </div>
            </div>
          </div>

          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker short"></span>Liquidations Firehose</span>
              <span class="cf-pill muted">!forceOrder@arr</span>
            </div>
            <div id="liqs-stream" phx-update="stream" class="cf-panel-body" style="padding: 0; max-height: 480px; overflow-y: auto;">
              <div :for={{dom_id, l} <- @streams.liquidations} id={dom_id}
                   class={"grid grid-cols-12 gap-2 px-3 py-1 mono " <> liq_flash_class(l.side)}
                   style="border-bottom: 1px solid var(--line); font-size: 11px;">
                <span class="col-span-2 cf-pill" style={liq_pill_style(l.side)}>{l.side}</span>
                <span class="col-span-3" style="color: var(--ink); font-weight: 600;">{l.symbol}</span>
                <span class="col-span-3 num" style="color: var(--ink-2);">{l.price}</span>
                <span class="col-span-2 num" style="color: var(--ink-3);">{l.qty}</span>
                <span class="col-span-2 num" style="color: var(--ink-3);">{Calendar.strftime(l.time, "%H:%M:%S")}</span>
              </div>
              <div class="px-3 py-6 text-center" style="color: var(--ink-3);">
                Listening · <span class="mono" style="color: var(--ink-mute);">all symbols</span>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.shell>
    """
  end

  # ── view helpers ────────────────────────────────────────────

  defp format_rate(nil), do: "—"

  defp format_rate(%Decimal{} = d) do
    pct = Decimal.mult(d, Decimal.new(100)) |> Decimal.round(4) |> Decimal.to_string(:normal)
    "#{pct}%"
  end

  defp format_rate(n), do: to_string(n)

  defp format_score(nil), do: ""
  defp format_score(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_score(n), do: to_string(n)

  defp rate_color(nil), do: "var(--ink-3)"

  defp rate_color(%Decimal{} = d) do
    if Decimal.gt?(d, 0), do: "var(--short)", else: "var(--long)"
  end

  defp rate_color(_), do: "var(--ink-3)"

  defp side_pill_style("long"), do: "background: var(--long-bg); color: var(--long);"
  defp side_pill_style("short"), do: "background: var(--short-bg); color: var(--short);"
  defp side_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp liq_pill_style("BUY"), do: "background: var(--short-bg); color: var(--short);"
  defp liq_pill_style("SELL"), do: "background: var(--long-bg); color: var(--long);"
  defp liq_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp liq_flash_class("BUY"), do: "cf-flash-short"
  defp liq_flash_class("SELL"), do: "cf-flash"
  defp liq_flash_class(_), do: ""
end

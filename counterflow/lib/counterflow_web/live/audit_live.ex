defmodule CounterflowWeb.AuditLive do
  @moduledoc """
  Audit log: a unified chronological view of every autonomous action the
  system has taken in the last 24 hours.

  Surfaces six event sources:
    * signal emitted          (signals table)
    * paper fill              (paper_fills)
    * auto-tune run           (auto_tune_runs)
    * watchlist promotion     (watchlist rows where promoted_by starts with "auto:")
    * kill switch engage      (killswitch_events)
    * risk rejection          (risk_rejections)

  Live-updates whenever a signal, paper fill, or auto-tune broadcast lands.
  """

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias CounterflowWeb.Layouts
  alias Counterflow.Repo
  alias Counterflow.Strategy.Signal
  alias Counterflow.Broker.PaperFill
  alias Counterflow.Risk.{KillswitchEvent, Rejection}
  alias Counterflow.Market.WatchlistEntry
  alias Phoenix.PubSub

  @window_hours 24

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(Counterflow.PubSub, "signals:new")
      PubSub.subscribe(Counterflow.PubSub, "auto_tune:done")
      :timer.send_interval(60_000, :refresh)
    end

    {:ok,
     socket
     |> assign(:current_path, "/audit")
     |> load_events()}
  end

  @impl true
  def handle_info({:signal, _sig}, socket), do: {:noreply, load_events(socket)}
  def handle_info({:auto_tune, _sym, _summary}, socket), do: {:noreply, load_events(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load_events(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_events(socket) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_hours * 3600, :second)

    events =
      Enum.concat([
        signal_events(cutoff),
        paper_fill_events(cutoff),
        auto_tune_events(cutoff),
        watchlist_events(cutoff),
        killswitch_events(cutoff),
        rejection_events(cutoff)
      ])
      |> Enum.sort_by(& &1.at, {:desc, DateTime})
      |> Enum.take(200)

    counts = %{
      signals: Enum.count(events, &(&1.kind == :signal)),
      fills: Enum.count(events, &(&1.kind == :fill)),
      auto_tune: Enum.count(events, &(&1.kind == :auto_tune)),
      promotions: Enum.count(events, &(&1.kind == :promotion)),
      killswitch: Enum.count(events, &(&1.kind == :killswitch)),
      rejections: Enum.count(events, &(&1.kind == :rejection))
    }

    socket
    |> assign(:events, events)
    |> assign(:counts, counts)
  end

  # ── source queries ──────────────────────────────────────────

  defp signal_events(cutoff) do
    Repo.all(
      from s in Signal,
        where: s.generated_at > ^cutoff,
        order_by: [desc: s.generated_at],
        limit: 60
    )
    |> Enum.map(fn s ->
      %{
        kind: :signal,
        at: s.generated_at,
        symbol: s.symbol,
        title: "Signal · #{String.upcase(s.side)} #{s.symbol}",
        detail: "score=#{format_decimal(s.score)} · #{s.interval} · entry #{s.price}",
        outcome: s.outcome
      }
    end)
  end

  defp paper_fill_events(cutoff) do
    Repo.all(
      from f in PaperFill,
        where: f.filled_at > ^cutoff,
        order_by: [desc: f.filled_at],
        limit: 60
    )
    |> Enum.map(fn f ->
      %{
        kind: :fill,
        at: f.filled_at,
        symbol: f.symbol,
        title: "Paper fill · #{f.side} #{f.symbol}",
        detail: "qty=#{f.qty} @ #{f.price} · fee=#{format_decimal(f.fee)}"
      }
    end)
  end

  defp auto_tune_events(cutoff) do
    Repo.all(
      from r in "auto_tune_runs",
        where: r.ran_at > ^cutoff,
        order_by: [desc: r.ran_at],
        limit: 30,
        select: %{
          symbol: r.symbol,
          interval: r.interval,
          ran_at: r.ran_at,
          previous_threshold: r.previous_threshold,
          selected_threshold: r.selected_threshold
        }
    )
    |> Enum.map(fn r ->
      change_arrow =
        case {r.previous_threshold, r.selected_threshold} do
          {nil, _} -> "—"
          {_, nil} -> "no winner"
          {p, s} -> "#{format_decimal(p)} → #{format_decimal(s)}"
        end

      %{
        kind: :auto_tune,
        at: to_datetime(r.ran_at),
        symbol: r.symbol,
        title: "Auto-tune · #{r.symbol}",
        detail: "threshold #{change_arrow} · interval=#{r.interval}"
      }
    end)
  end

  defp watchlist_events(cutoff) do
    Repo.all(
      from w in WatchlistEntry,
        where:
          w.added_at > ^cutoff and not is_nil(w.promoted_by) and
            like(w.promoted_by, "auto:%"),
        order_by: [desc: w.added_at],
        limit: 30
    )
    |> Enum.map(fn w ->
      %{
        kind: :promotion,
        at: w.added_at,
        symbol: w.symbol,
        title: "Watchlist promotion · #{w.symbol}",
        detail: "by #{w.promoted_by} · score=#{format_decimal(w.promoted_score)}"
      }
    end)
  end

  defp killswitch_events(cutoff) do
    Repo.all(
      from e in KillswitchEvent,
        where: e.engaged_at > ^cutoff,
        order_by: [desc: e.engaged_at],
        limit: 20
    )
    |> Enum.map(fn e ->
      %{
        kind: :killswitch,
        at: e.engaged_at,
        symbol: nil,
        title: "Kill switch ENGAGED · by #{e.engaged_by}",
        detail:
          "#{e.reason}#{if e.released_at, do: " · released " <> Calendar.strftime(e.released_at, "%H:%M:%S"), else: " · STILL ACTIVE"}"
      }
    end)
  end

  defp rejection_events(cutoff) do
    Repo.all(
      from r in Rejection,
        where: r.attempted_at > ^cutoff,
        order_by: [desc: r.attempted_at],
        limit: 30
    )
    |> Enum.map(fn r ->
      %{
        kind: :rejection,
        at: r.attempted_at,
        symbol: r.symbol,
        title: "Risk rejection · #{r.symbol || "—"}",
        detail: "gate=#{r.rejected_by}"
      }
    end)
  end

  # ── view ────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">
            AUDIT · <span class="mono" style="color: var(--ink-3);">last {window_hours_label()} hours</span>
          </h1>
          <span class="cf-pill muted">{length(@events)} events</span>
        </header>

        <section class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
          <div class="cf-kpi long">
            <div class="cf-kpi-label">Signals</div>
            <div class="cf-kpi-value">{@counts.signals}</div>
          </div>
          <div class="cf-kpi">
            <div class="cf-kpi-label">Paper fills</div>
            <div class="cf-kpi-value">{@counts.fills}</div>
          </div>
          <div class="cf-kpi warn">
            <div class="cf-kpi-label">Auto-tunes</div>
            <div class="cf-kpi-value">{@counts.auto_tune}</div>
          </div>
          <div class="cf-kpi">
            <div class="cf-kpi-label">Promotions</div>
            <div class="cf-kpi-value">{@counts.promotions}</div>
          </div>
          <div class="cf-kpi short">
            <div class="cf-kpi-label">Kill switch</div>
            <div class="cf-kpi-value">{@counts.killswitch}</div>
          </div>
          <div class="cf-kpi short">
            <div class="cf-kpi-label">Rejections</div>
            <div class="cf-kpi-value">{@counts.rejections}</div>
          </div>
        </section>

        <div class="cf-panel">
          <div class="cf-panel-head">
            <span class="title"><span class="marker"></span>Event timeline</span>
            <span class="cf-pill muted">newest first</span>
          </div>
          <table class="cf-table">
            <thead>
              <tr>
                <th>Time</th>
                <th>Kind</th>
                <th>Title</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @events}>
                <td class="num" style="color: var(--ink-3);">{Calendar.strftime(e.at, "%m-%d %H:%M:%S")}</td>
                <td>
                  <span class={"cf-pill " <> kind_class(e.kind)} style={kind_style(e.kind)}>
                    {kind_label(e.kind)}
                  </span>
                </td>
                <td>
                  <span :if={e.symbol} style="color: var(--ink-3);">
                  </span>
                  <a :if={e.symbol} href={~p"/symbol/#{e.symbol}"} style="color: var(--ink); font-weight: 600;">
                    {e.symbol}
                  </a>
                  <span :if={!e.symbol} style="color: var(--ink); font-weight: 600;">{e.title}</span>
                  <span :if={e.symbol} style="color: var(--ink-3);"> · {Map.get(e, :title, "")}</span>
                </td>
                <td style="color: var(--ink-2); font-size: 11px;">{e.detail}</td>
              </tr>
              <tr :if={@events == []}>
                <td colspan="4" class="text-center py-8" style="color: var(--ink-3);">
                  Nothing happened in the last {window_hours_label()} hours yet — leave the system running and check back.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.shell>
    """
  end

  defp window_hours_label, do: @window_hours

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp to_datetime(other), do: other

  defp kind_label(:signal), do: "SIGNAL"
  defp kind_label(:fill), do: "FILL"
  defp kind_label(:auto_tune), do: "AUTO-TUNE"
  defp kind_label(:promotion), do: "PROMOTE"
  defp kind_label(:killswitch), do: "KILLSWITCH"
  defp kind_label(:rejection), do: "REJECT"

  defp kind_class(_), do: ""

  defp kind_style(:signal), do: "background: var(--long-bg); color: var(--long);"
  defp kind_style(:fill), do: "background: var(--long-bg); color: var(--long);"
  defp kind_style(:auto_tune), do: "background: var(--warn-bg); color: var(--warn);"
  defp kind_style(:promotion), do: "background: var(--warn-bg); color: var(--warn);"
  defp kind_style(:killswitch), do: "background: var(--short-bg); color: var(--short);"
  defp kind_style(:rejection), do: "background: var(--short-bg); color: var(--short);"
  defp kind_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp format_decimal(nil), do: "—"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_decimal(other), do: to_string(other)

  # Inject @window_hours into assigns so the template can read it without
  # touching the module attribute directly.
  def render_window_hours, do: @window_hours
end

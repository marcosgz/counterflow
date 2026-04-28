defmodule CounterflowWeb.DebugLive do
  @moduledoc """
  Strategy diagnostics. Shows the latest evaluation per (symbol, interval),
  with the score, the threshold, the side, and the reason it didn't fire
  (or that it did). Live-updates on every closed candle.
  """

  use CounterflowWeb, :live_view

  alias CounterflowWeb.Layouts
  alias Counterflow.Strategy.Diagnostics
  alias Phoenix.PubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe(Counterflow.PubSub, "diagnostics:update")

    {:ok,
     socket
     |> assign(:current_path, "/debug")
     |> assign(:rows, Diagnostics.snapshot())}
  end

  @impl true
  def handle_info({:diag, _sym, _int, _row}, socket) do
    {:noreply, assign(socket, :rows, Diagnostics.snapshot())}
  end

  @impl true
  def handle_event("force_eval", _params, socket) do
    Counterflow.Strategy.Pipeline.force_evaluate_all()
    {:noreply, put_flash(socket, :info, "Forcing evaluation against latest closed candles…")}
  end

  def handle_event("reset", _params, socket) do
    Counterflow.Strategy.Diagnostics.reset()
    {:noreply, assign(socket, :rows, [])}
  end

  @impl true
  def render(assigns) do
    rows = assigns.rows
    summary = summarize(rows)
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between flex-wrap gap-2">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">
            STRATEGY DEBUG · <span class="mono" style="color: var(--ink-3);">{length(@rows)} active streams</span>
          </h1>
          <div class="flex items-center gap-2">
            <button phx-click="force_eval" class="cf-btn primary">
              <.icon name="hero-arrow-path-mini" class="size-4" /> Refresh now
            </button>
            <button phx-click="reset" class="cf-btn">
              Clear
            </button>
            <span class="cf-pill muted">live</span>
          </div>
        </header>

        <%!-- Summary by reason --%>
        <section class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-7 gap-2">
          <div :for={{reason, count} <- @summary.by_reason}
               class={"cf-kpi " <> reason_kpi_class(reason)}
               style="padding: 10px 12px;">
            <div class="cf-kpi-label" style="font-size: 9px;">{reason_label(reason)}</div>
            <div class="cf-kpi-value" style="font-size: 16px;">{count}</div>
          </div>
          <div class="cf-kpi" style="padding: 10px 12px;">
            <div class="cf-kpi-label" style="font-size: 9px;">avg score</div>
            <div class="cf-kpi-value" style="font-size: 16px;">{@summary.avg_score}</div>
          </div>
          <div class="cf-kpi" style="padding: 10px 12px;">
            <div class="cf-kpi-label" style="font-size: 9px;">max score</div>
            <div class="cf-kpi-value" style="font-size: 16px;">{@summary.max_score}</div>
          </div>
        </section>

        <%!-- Per-symbol table --%>
        <div class="cf-panel cf-panel-flush">
          <div class="cf-panel-head">
            <span class="title"><span class="marker"></span>Latest Evaluation per Symbol</span>
            <span class="cf-pill muted">refreshes on every closed candle</span>
          </div>
          <div style="overflow-x: auto;">
            <table class="cf-table">
              <thead>
                <tr>
                  <th>Symbol · Interval</th>
                  <th>Reason</th>
                  <th>Side</th>
                  <th class="num">Score</th>
                  <th class="num">Threshold</th>
                  <th class="num">Δ</th>
                  <th>Top components</th>
                  <th class="num">Candle</th>
                  <th class="num">Evaluated</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>
                    <a href={~p"/symbol/#{row.symbol}"}
                       style="color: var(--ink); font-weight: 600;">{row.symbol}</a>
                    <span style="color: var(--ink-3);">· {row.interval}</span>
                  </td>
                  <td>
                    <span class={"cf-pill " <> reason_pill_class(row.reason)} style={reason_pill_style(row.reason)}>
                      {reason_label(row.reason)}
                    </span>
                  </td>
                  <td>
                    <span :if={Map.get(row, :side)} class="cf-pill" style={side_pill_style(Map.get(row, :side))}>
                      {String.upcase(to_string(Map.get(row, :side)))}
                    </span>
                    <span :if={!Map.get(row, :side)} style="color: var(--ink-3);">—</span>
                  </td>
                  <td class="num">{format_score(Map.get(row, :score))}</td>
                  <td class="num" style="color: var(--ink-3);">{format_score(Map.get(row, :threshold))}</td>
                  <td class="num" style={delta_style(Map.get(row, :score), Map.get(row, :threshold))}>
                    {format_delta(Map.get(row, :score), Map.get(row, :threshold))}
                  </td>
                  <td style="font-size: 10px; color: var(--ink-3);">
                    {top_components(Map.get(row, :components))}
                  </td>
                  <td class="num" style="color: var(--ink-3);">
                    {format_time(Map.get(row, :candle_time))}
                  </td>
                  <td class="num" style="color: var(--ink-3);">
                    {Calendar.strftime(row.evaluated_at, "%H:%M:%S")}
                  </td>
                </tr>
                <tr :if={@rows == []}>
                  <td colspan="9" class="text-center py-8" style="color: var(--ink-3);">
                    No evaluations yet — waiting for the next closed candle on watchlist symbols.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <details class="cf-panel cf-panel-flush">
          <summary class="cf-panel-head" style="cursor: pointer;">
            <span class="title"><span class="marker warn"></span>Reason legend</span>
          </summary>
          <div class="cf-panel-body grid grid-cols-1 md:grid-cols-2 gap-2 text-xs mono" style="color: var(--ink-2);">
            <div><span class="cf-pill" style="background: var(--long-bg); color: var(--long);">EMITTED</span> — signal dispatched, paper-trade fired if enabled, outcome being tracked</div>
            <div><span class="cf-pill muted">NEUTRAL</span> — directional cues didn't agree on a side</div>
            <div><span class="cf-pill" style="background: var(--warn-bg); color: var(--warn);">BELOW THR</span> — bias OK but composite score below threshold (tune in /settings/:symbol)</div>
            <div><span class="cf-pill muted">TREND</span> — score OK but EMA-stack rejected the side</div>
            <div><span class="cf-pill" style="background: var(--short-bg); color: var(--short);">SIDE OFF</span> — config has long or short disabled for this symbol</div>
            <div><span class="cf-pill muted">COOLDOWN</span> — duplicate within cooldown_minutes window</div>
            <div><span class="cf-pill muted">DISABLED</span> — symbol's `enabled` flag is off</div>
            <div><span class="cf-pill muted">TF LOW</span> — TF level &lt; min_tf_level (config gate)</div>
            <div><span class="cf-pill" style="background: var(--short-bg); color: var(--short);">ERROR</span> — exception during evaluation; check logs</div>
          </div>
        </details>
      </div>
    </Layouts.shell>
    """
  end

  # ── helpers ─────────────────────────────────────────────────

  defp summarize(rows) do
    by_reason =
      rows
      |> Enum.group_by(& &1.reason)
      |> Enum.map(fn {r, v} -> {r, length(v)} end)
      |> Enum.sort_by(fn {_, n} -> -n end)

    scores =
      rows
      |> Enum.map(&Map.get(&1, :score))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_float/1)

    avg = if scores == [], do: "—", else: Float.round(Enum.sum(scores) / length(scores), 3)
    max = if scores == [], do: "—", else: Float.round(Enum.max(scores), 3)

    %{by_reason: by_reason, avg_score: avg, max_score: max}
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(_), do: 0.0

  defp top_components(nil), do: ""
  defp top_components(map) when map_size(map) == 0, do: ""

  defp top_components(map) do
    map
    |> Enum.map(fn {k, v} -> {k, to_float(v)} end)
    |> Enum.sort_by(fn {_, v} -> -abs(v) end)
    |> Enum.take(3)
    |> Enum.map(fn {k, v} ->
      sign = if v >= 0, do: "+", else: ""
      "#{k}=#{sign}#{Float.round(v, 2)}"
    end)
    |> Enum.join(" ")
  end

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: "—"

  defp format_score(nil), do: "—"
  defp format_score(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 3), :normal)
  defp format_score(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 3)
  defp format_score(other), do: to_string(other)

  defp format_delta(score, threshold) when is_number(score) and is_number(threshold) do
    diff = score - threshold
    sign = if diff >= 0, do: "+", else: ""
    "#{sign}#{Float.round(diff, 3)}"
  end

  defp format_delta(_, _), do: "—"

  defp delta_style(score, threshold) when is_number(score) and is_number(threshold) do
    if score >= threshold, do: "color: var(--long);", else: "color: var(--short);"
  end

  defp delta_style(_, _), do: "color: var(--ink-3);"

  defp reason_label(:emitted), do: "EMITTED"
  defp reason_label(:neutral), do: "NEUTRAL"
  defp reason_label(:below_threshold), do: "BELOW THR"
  defp reason_label(:trend_filter), do: "TREND"
  defp reason_label(:side_disabled), do: "SIDE OFF"
  defp reason_label(:cooldown), do: "COOLDOWN"
  defp reason_label(:precheck_disabled), do: "DISABLED"
  defp reason_label(:precheck_tf_low), do: "TF LOW"
  defp reason_label(:error), do: "ERROR"
  defp reason_label(other), do: to_string(other) |> String.upcase()

  defp reason_pill_class(_), do: ""

  defp reason_pill_style(:emitted), do: "background: var(--long-bg); color: var(--long);"
  defp reason_pill_style(:below_threshold), do: "background: var(--warn-bg); color: var(--warn);"
  defp reason_pill_style(:side_disabled), do: "background: var(--short-bg); color: var(--short);"
  defp reason_pill_style(:error), do: "background: var(--short-bg); color: var(--short);"
  defp reason_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp reason_kpi_class(:emitted), do: "long"
  defp reason_kpi_class(:below_threshold), do: "warn"
  defp reason_kpi_class(:side_disabled), do: "short"
  defp reason_kpi_class(:error), do: "short"
  defp reason_kpi_class(_), do: ""

  defp side_pill_style(:long), do: "background: var(--long-bg); color: var(--long);"
  defp side_pill_style(:short), do: "background: var(--short-bg); color: var(--short);"
  defp side_pill_style("long"), do: "background: var(--long-bg); color: var(--long);"
  defp side_pill_style("short"), do: "background: var(--short-bg); color: var(--short);"
  defp side_pill_style(_), do: "background: var(--line); color: var(--ink-3);"
end

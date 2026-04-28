defmodule CounterflowWeb.BacktestLive do
  @moduledoc """
  Backtest launcher + result viewer. Pick a symbol, interval, lookback
  window, and threshold; on submit we run the historical Replayer +
  outcome evaluator and show the resulting signal density and win-rate
  metrics. Use this to calibrate thresholds before tuning live config.
  """

  use CounterflowWeb, :live_view

  alias CounterflowWeb.Layouts
  alias Counterflow.{Backtest.Runner, Watchlist}

  @impl true
  def mount(_params, _session, socket) do
    watchlist = Watchlist.all() |> Enum.map(& &1.symbol)
    default_symbol = List.first(watchlist) || "BTCUSDT"

    {:ok,
     socket
     |> assign(:current_path, "/backtest")
     |> assign(:watchlist, watchlist)
     |> assign(:form, default_form(default_symbol))
     |> assign(:running?, false)
     |> assign(:result, nil)
     |> assign(:error, nil)}
  end

  defp default_form(symbol) do
    %{
      "symbol" => symbol,
      "interval" => "5m",
      "days" => "3",
      "threshold" => "0.40"
    }
  end

  @impl true
  def handle_event("change", %{"_target" => _, "form" => form}, socket) do
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("run", %{"form" => form}, socket) do
    case parse_form(form) do
      {:ok, opts} ->
        parent = self()

        Task.start(fn ->
          try do
            result = Runner.run(opts)
            send(parent, {:backtest_done, result, opts})
          rescue
            e -> send(parent, {:backtest_error, Exception.message(e)})
          end
        end)

        {:noreply,
         socket
         |> assign(:running?, true)
         |> assign(:error, nil)
         |> assign(:form, form)}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason, form: form)}
    end
  end

  @impl true
  def handle_info({:backtest_done, result, opts}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> assign(:result, Map.put(result, :opts, opts))}
  end

  def handle_info({:backtest_error, msg}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> assign(:error, msg)}
  end

  defp parse_form(form) do
    with {days, ""} when days > 0 <- Integer.parse(form["days"] || "3"),
         {threshold, ""} when threshold >= 0 <- Float.parse(form["threshold"] || "0.4") do
      symbol = form["symbol"]
      interval = form["interval"]
      to = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      from = DateTime.add(to, -days * 86_400, :second)

      {:ok,
       [
         symbol: symbol,
         interval: interval,
         from: from,
         to: to,
         strategy_opts: [threshold: threshold]
       ]}
    else
      _ -> {:error, "Invalid form values."}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between flex-wrap gap-2">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">
            BACKTEST · <span class="mono" style="color: var(--ink-3);">historical replay → outcomes</span>
          </h1>
          <span class="cf-pill muted">deterministic</span>
        </header>

        <%!-- Form --%>
        <div class="cf-panel cf-panel-flush">
          <div class="cf-panel-head">
            <span class="title"><span class="marker"></span>Configuration</span>
          </div>
          <form phx-submit="run" phx-change="change" class="cf-panel-body grid grid-cols-1 md:grid-cols-5 gap-3 items-end">
            <label class="flex flex-col gap-1">
              <span class="cf-section-title" style="padding: 0;">Symbol</span>
              <select name="form[symbol]" class="cf-select">
                <option :for={s <- @watchlist} value={s} selected={@form["symbol"] == s}>{s}</option>
              </select>
            </label>
            <label class="flex flex-col gap-1">
              <span class="cf-section-title" style="padding: 0;">Interval</span>
              <select name="form[interval]" class="cf-select">
                <option :for={i <- ["1m", "5m", "15m", "1h"]} value={i} selected={@form["interval"] == i}>{i}</option>
              </select>
            </label>
            <label class="flex flex-col gap-1">
              <span class="cf-section-title" style="padding: 0;">Days back</span>
              <input type="number" min="1" max="90" name="form[days]" value={@form["days"]} class="cf-input" />
            </label>
            <label class="flex flex-col gap-1">
              <span class="cf-section-title" style="padding: 0;">Threshold (0..1)</span>
              <input type="number" step="0.01" min="0" max="1" name="form[threshold]" value={@form["threshold"]} class="cf-input" />
            </label>
            <div class="flex flex-col gap-1">
              <button type="submit" class="cf-btn primary justify-center" disabled={@running?}>
                <%= if @running?, do: "Running…", else: "Run Backtest" %>
              </button>
              <span :if={@error} class="text-xs mono" style="color: var(--short);">{@error}</span>
            </div>
          </form>
        </div>

        <%!-- Result --%>
        <div :if={@result} class="space-y-3">
          <section class="grid grid-cols-2 md:grid-cols-6 gap-3">
            <.kpi label="Signals" value={@result.summary.total} />
            <.kpi label="Win rate" value={pct(@result.summary.win_rate)} variant={class_for_winrate(@result.summary.win_rate)} />
            <.kpi label="Profit Factor" value={fmt(@result.summary.profit_factor, 2)} variant={class_for_pf(@result.summary.profit_factor)} />
            <.kpi label="Avg R" value={fmt(@result.summary.avg_r, 2)} variant={class_for_r(@result.summary.avg_r)} />
            <.kpi label="Sum R" value={fmt(@result.summary.sum_r, 2)} variant={class_for_r(@result.summary.sum_r)} />
            <.kpi label="Max DD (R)" value={fmt(@result.summary.max_drawdown_r, 2)} variant="warn" />
          </section>

          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker"></span>Replay context</span>
              <span class="cf-pill muted">{@result.replay.candles_processed} candles · {@result.replay.duration_ms}ms</span>
            </div>
          </div>

          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker short"></span>Signals</span>
              <span class="cf-pill muted">{length(@result.signals)} total</span>
            </div>
            <div style="overflow-x: auto;">
              <table class="cf-table">
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Side</th>
                    <th class="num">Entry</th>
                    <th class="num">SL</th>
                    <th class="num">TP1</th>
                    <th class="num">TP2</th>
                    <th class="num">Score</th>
                    <th>Outcome</th>
                    <th class="num">R</th>
                    <th class="num">Peak R / Trough R</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{sig, outcome} <- @result.signals}>
                    <td class="num" style="color: var(--ink-3);">
                      {Calendar.strftime(sig.generated_at, "%m-%d %H:%M")}
                    </td>
                    <td>
                      <span class="cf-pill" style={side_pill_style(sig.side)}>{String.upcase(sig.side)}</span>
                    </td>
                    <td class="num">{sig.price}</td>
                    <td class="num" style="color: var(--short);">{sig.sl}</td>
                    <td class="num" style="color: var(--long);">{sig.tp1}</td>
                    <td class="num" style="color: var(--long);">{sig.tp2}</td>
                    <td class="num">{sig.score}</td>
                    <td>{outcome_pill(outcome)}</td>
                    <td class="num" style={r_color(outcome.r_multiple)}>{fmt(outcome.r_multiple, 2)}</td>
                    <td class="num" style="color: var(--ink-3);">
                      {fmt(outcome.peak_R, 2)} / {fmt(outcome.trough_R, 2)}
                    </td>
                  </tr>
                  <tr :if={@result.signals == []}>
                    <td colspan="10" class="text-center py-8" style="color: var(--ink-3);">
                      No signals at this threshold. Lower it and re-run.
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <div :if={!@result and !@running?} class="cf-panel cf-panel-flush">
          <div class="cf-panel-body text-center py-12 mono" style="color: var(--ink-3); font-size: 12px;">
            Pick a symbol, lookback window, and threshold above, then run.
            Use this to find a threshold where signal density × win-rate is acceptable
            before tuning <a href={~p"/settings"} style="color: var(--ink); text-decoration: underline;">live config</a>.
          </div>
        </div>
      </div>
    </Layouts.shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :variant, :string, default: ""

  defp kpi(assigns) do
    ~H"""
    <div class={"cf-kpi " <> @variant}>
      <div class="cf-kpi-label">{@label}</div>
      <div class="cf-kpi-value">{@value}</div>
    </div>
    """
  end

  defp pct(n) when is_number(n), do: "#{Float.round(n * 100, 1)}%"
  defp pct(_), do: "—"

  defp fmt(nil, _), do: "—"
  defp fmt(n, dec) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: dec)
  defp fmt(other, _), do: to_string(other)

  defp class_for_winrate(wr) when is_number(wr) and wr >= 0.55, do: "long"
  defp class_for_winrate(wr) when is_number(wr) and wr < 0.45, do: "short"
  defp class_for_winrate(_), do: ""

  defp class_for_pf(pf) when is_number(pf) and pf >= 1.3, do: "long"
  defp class_for_pf(pf) when is_number(pf) and pf < 1.0, do: "short"
  defp class_for_pf(_), do: ""

  defp class_for_r(r) when is_number(r) and r > 0, do: "long"
  defp class_for_r(r) when is_number(r) and r < 0, do: "short"
  defp class_for_r(_), do: ""

  defp side_pill_style("long"), do: "background: var(--long-bg); color: var(--long);"
  defp side_pill_style("short"), do: "background: var(--short-bg); color: var(--short);"
  defp side_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp r_color(r) when is_number(r) and r > 0, do: "color: var(--long);"
  defp r_color(r) when is_number(r) and r < 0, do: "color: var(--short);"
  defp r_color(_), do: "color: var(--ink-3);"

  defp outcome_pill(%{hit_tp2: true}),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill" style="background: var(--long-bg); color: var(--long);">TP2</span>|)

  defp outcome_pill(%{hit_tp1: true}),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill" style="background: var(--long-bg); color: var(--long);">TP1</span>|)

  defp outcome_pill(%{hit_sl: true}),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill" style="background: var(--short-bg); color: var(--short);">SL</span>|)

  defp outcome_pill(_),
    do: Phoenix.HTML.raw(~S|<span class="cf-pill muted">EXPIRED</span>|)
end

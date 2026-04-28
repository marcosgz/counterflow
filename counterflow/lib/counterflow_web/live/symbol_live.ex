defmodule CounterflowWeb.SymbolLive do
  @moduledoc """
  Trader-grade single-symbol view.

  Layout (desktop):
      ┌────────────────────────────┬────────────┐
      │ TradingView (price)        │ TICKER     │
      │                            │ stats +    │
      ├────────────────────────────┤ levels +   │
      │ Open Interest              │ signals    │
      ├────────────────────────────┤            │
      │ Smart Money Level          │            │
      ├────────────────────────────┤            │
      │ RSI (with bands)           │            │
      ├────────────────────────────┤            │
      │ Exponential                │            │
      └────────────────────────────┴────────────┘

  All Chart.js panels share a x-axis time domain (last 60 closed candles)
  and use the preset hooks defined in assets/js/hooks/chart_js.js to mirror
  the look of the original Encryptos / Coinalyze indicator widgets.
  """

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias CounterflowWeb.Layouts
  alias Counterflow.{Repo, Ingest.SymbolWorker}
  alias Counterflow.Strategy.Signal
  alias Counterflow.Market.{OpenInterest, LongShortRatio, FundingRate}
  alias Counterflow.Indicators.{BucketedForce, EMA, RSI, LSRSignal}
  alias Phoenix.PubSub

  @history 60

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

    {:ok,
     socket
     |> assign(:current_path, "/symbol/#{symbol}")
     |> assign(:symbol, symbol)
     |> assign(:interval, interval)
     |> assign(:candles, candles)
     |> assign(:signals, recent_signals(symbol))
     |> assign(:hunter, hunter_matrix(symbol))
     |> assign(:level_pct, level_pct(symbol, interval))}
  end

  @impl true
  def handle_info(:hydrate_charts, socket), do: {:noreply, push_chart_data(socket)}

  def handle_info({:candle, _kind, candle}, socket) do
    candles =
      socket.assigns.candles
      |> Enum.reject(&(&1.time == candle.time and not &1.closed))
      |> Kernel.++([candle])
      |> Enum.take(-@history)

    socket =
      socket
      |> assign(:candles, candles)
      |> push_chart_data()

    {:noreply, socket}
  end

  def handle_info({:signal, sig}, socket) do
    {:noreply,
     socket
     |> assign(:signals, [sig | socket.assigns.signals] |> Enum.take(20))
     |> assign(:hunter, hunter_matrix(socket.assigns.symbol))
     |> assign(:level_pct, level_pct(socket.assigns.symbol, socket.assigns.interval))}
  end

  def handle_info({:liquidation, _}, socket), do: {:noreply, socket}

  defp push_chart_data(socket) do
    symbol = socket.assigns.symbol
    candles = socket.assigns.candles |> Enum.filter(& &1.closed)
    labels = Enum.map(candles, &Calendar.strftime(&1.time, "%H:%M"))

    socket
    |> push_event("chart:update:chart-oi", oi_payload(symbol, labels))
    |> push_event("chart:update:chart-level", level_payload(candles, labels))
    |> push_event("chart:update:chart-rsi", rsi_payload(candles, labels))
    |> push_event("chart:update:chart-exp", exp_payload(candles, labels))
    |> push_event("chart:update:chart-lsr", lsr_payload(symbol))
    |> push_event("chart:update:chart-funding", funding_payload(symbol))
  end

  defp oi_payload(symbol, _labels) do
    rows = load_oi(symbol)

    %{
      labels: Enum.map(rows, &Calendar.strftime(&1.time, "%H:%M")),
      values: Enum.map(rows, &Decimal.to_float(&1.open_interest))
    }
  end

  defp level_payload(candles, labels) do
    series =
      candles
      |> sliding_levels()

    %{labels: labels, values: series}
  end

  defp rsi_payload(candles, labels) do
    closes = Enum.map(candles, & &1.close)
    rsi_series = RSI.calculate(closes, 14) |> Enum.map(&(&1 || nil))
    %{labels: labels, values: rsi_series}
  end

  defp exp_payload(candles, labels) do
    # Trade-Force (TF) sliding values: ratio of trade count to rolling avg.
    tf_series = sliding_tf_values(candles)
    %{labels: labels, values: tf_series}
  end

  defp lsr_payload(symbol) do
    rows =
      Repo.all(
        from l in LongShortRatio,
          where: l.symbol == ^symbol and l.source == "global_account",
          order_by: [desc: l.time],
          limit: 30
      )
      |> Enum.reverse()

    %{
      labels: Enum.map(rows, &Calendar.strftime(&1.time, "%H:%M")),
      values: Enum.map(rows, &Decimal.to_float(&1.ls_ratio))
    }
  end

  defp funding_payload(symbol) do
    rows =
      Repo.all(
        from f in FundingRate,
          where: f.symbol == ^symbol,
          order_by: [desc: f.time],
          limit: 30
      )
      |> Enum.reverse()

    %{
      labels: Enum.map(rows, &Calendar.strftime(&1.time, "%H:%M")),
      values: Enum.map(rows, &Decimal.to_float(&1.funding_rate))
    }
  end

  # Sliding window: for each candle index i, compute TF level on candles[..i]
  # so the chart shows the indicator's value AS OF each bar (mirrors how the
  # legacy indicator paints level-coloured bars over time).
  defp sliding_levels(candles) do
    candles
    |> Enum.with_index()
    |> Enum.map(fn {_c, i} ->
      window = Enum.slice(candles, 0..i)
      result = BucketedForce.calculate(window, &BucketedForce.trades_extractor/1)
      result.level
    end)
  end

  defp sliding_tf_values(candles) do
    candles
    |> Enum.with_index()
    |> Enum.map(fn {_c, i} ->
      window = Enum.slice(candles, 0..i)
      result = BucketedForce.calculate(window, &BucketedForce.trades_extractor/1)
      avg = result.avg
      latest = result.latest
      if avg > 0, do: latest / avg, else: 0.0
    end)
  end

  # ── Hunter matrix (mirrors the Smart Money Hunter top-right table) ──

  defp hunter_matrix(symbol) do
    intervals = ["1m", "5m", "15m", "30m", "1h", "4h", "1D"]

    Enum.map(intervals, fn interval ->
      level =
        Repo.one(
          from c in Counterflow.Market.Candle,
            where: c.symbol == ^symbol and c.interval == ^interval and c.closed == true,
            order_by: [desc: c.time],
            limit: 1
        )
        |> case do
          nil -> nil
          _candle -> nil
        end

      # Pull last 60 closed candles per interval and compute TF + RSI; expose
      # 3 buckets: EXP (TF), RSI bucket, ELV (volume force) — mirroring the
      # Encryptos hunter widget.
      series =
        Repo.all(
          from c in Counterflow.Market.Candle,
            where: c.symbol == ^symbol and c.interval == ^interval and c.closed == true,
            order_by: [desc: c.time],
            limit: 60
        )
        |> Enum.reverse()

      tf =
        if series == [] do
          %{level: 0}
        else
          BucketedForce.calculate(series, &BucketedForce.trades_extractor/1)
        end

      vf =
        if series == [] do
          %{level: 0}
        else
          BucketedForce.calculate(series, &BucketedForce.volume_extractor/1)
        end

      rsi_value =
        if length(series) < 15 do
          nil
        else
          RSI.last(Enum.map(series, & &1.close), 14)
        end

      %{
        interval: interval,
        exp_level: tf.level,
        rsi_level: rsi_to_level(rsi_value),
        vol_level: vf.level,
        _level_unused: level
      }
    end)
  end

  defp rsi_to_level(nil), do: 0
  defp rsi_to_level(rsi) when is_number(rsi) do
    cond do
      rsi >= 80 -> 6
      rsi >= 70 -> 5
      rsi >= 60 -> 3
      rsi >= 50 -> 2
      rsi >= 40 -> 1
      rsi >= 30 -> 2
      rsi >= 20 -> 5
      true -> 6
    end
  end

  defp level_pct(symbol, interval) do
    series =
      Repo.all(
        from c in Counterflow.Market.Candle,
          where: c.symbol == ^symbol and c.interval == ^interval and c.closed == true,
          order_by: [desc: c.time],
          limit: 60
      )
      |> Enum.reverse()

    case series do
      [] ->
        0.0

      _ ->
        tf = BucketedForce.calculate(series, &BucketedForce.trades_extractor/1)
        # Map 0..6 to 0..100%
        min(tf.level / 6.0, 1.0) * 100
    end
  end

  defp load_candles(symbol, interval) do
    case SymbolWorker.snapshot(symbol, interval) do
      %{closed: closed, open: open} -> Enum.take(closed, -@history) ++ List.wrap(open)
      _ -> []
    end
  end

  defp load_oi(symbol) do
    Repo.all(from o in OpenInterest, where: o.symbol == ^symbol, order_by: [desc: o.time], limit: 30)
    |> Enum.reverse()
  end

  defp recent_signals(symbol) do
    Repo.all(from s in Signal, where: s.symbol == ^symbol, order_by: [desc: s.generated_at], limit: 20)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path} symbol={@symbol}>
      <div class="px-3 sm:px-5 py-3 w-full space-y-3">
        <%!-- ── ticker strip ── --%>
        <section class="cf-panel">
          <div class="grid grid-cols-2 sm:grid-cols-5 lg:grid-cols-7 divide-x" style="border-color: var(--line);">
            <.ticker_cell label="Symbol" value={@symbol} highlight />
            <.ticker_cell label="Interval" value={@interval} />
            <.ticker_cell label="Last" value={last_close(@candles)} />
            <.ticker_cell label="Trades" value={last_trades(@candles)} />
            <.ticker_cell label="EMA(7)" value={format_num(latest_ema(@candles, 7))} />
            <.ticker_cell label="EMA(25)" value={format_num(latest_ema(@candles, 25))} />
            <.ticker_cell label="LSR(rsi)" value={format_num(lsr_rsi(@symbol))} />
          </div>
        </section>

        <%!-- ── main two-column layout ── --%>
        <section class="grid grid-cols-1 xl:grid-cols-[1fr_320px] gap-3">
          <div class="space-y-3">
            <%!-- Price chart (TradingView) --%>
            <div class="cf-panel">
              <div class="cf-panel-head">
                <span class="title"><span class="marker"></span>Price · TradingView</span>
                <span class="cf-pill muted">BINANCE:{@symbol}.P</span>
              </div>
              <div
                id={"tv-#{@symbol}"}
                phx-hook="TradingViewWidget"
                phx-update="ignore"
                data-symbol={@symbol}
                data-interval="5"
                style="width: 100%; height: 460px;"
              ></div>
            </div>

            <%!-- Open Interest --%>
            <div class="cf-panel">
              <div class="cf-ind-head">
                <span>Open Interest · 5m</span>
                <span class="vals">
                  <span class="pos">{Decimal.to_string(latest_oi(@symbol) || Decimal.new(0), :normal)}</span>
                </span>
              </div>
              <div class="cf-chart-wrap">
                <canvas id="chart-oi" phx-hook="ChartJSPanel" data-preset="oi"></canvas>
              </div>
            </div>

            <%!-- Smart Money Level (TF level history) --%>
            <div class="cf-panel">
              <div class="cf-ind-head">
                <span>Smart Money Level · TF(trades)</span>
                <span class="vals mono">
                  <span style="color: var(--ink-3);">level</span>
                  <span style="color: var(--ink); font-weight: 700;">{trunc(@level_pct / 100 * 6)}/6</span>
                </span>
              </div>
              <div class="cf-chart-wrap">
                <canvas id="chart-level" phx-hook="ChartJSPanel" data-preset="level"></canvas>
              </div>
            </div>

            <%!-- RSI with bands --%>
            <div class="cf-panel">
              <div class="cf-ind-head">
                <span>RSI · 14</span>
                <span class="vals mono">
                  <span style="color: var(--ink-3);">last</span>
                  <span style={"color: " <> rsi_color(latest_rsi(@candles))}>{format_num(latest_rsi(@candles))}</span>
                </span>
              </div>
              <div class="cf-chart-wrap">
                <canvas id="chart-rsi" phx-hook="ChartJSPanel" data-preset="rsi"></canvas>
              </div>
            </div>

            <%!-- Exponential (TF ratio bars) --%>
            <div class="cf-panel">
              <div class="cf-ind-head">
                <span>Exponential · TF / avg(TF)</span>
                <span class="vals mono"><span style="color: var(--ink-3);">acceleration on trades</span></span>
              </div>
              <div class="cf-chart-wrap short">
                <canvas id="chart-exp" phx-hook="ChartJSPanel" data-preset="exp"></canvas>
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
              <%!-- L/S Ratio --%>
              <div class="cf-panel">
                <div class="cf-ind-head">
                  <span>Long/Short Ratio · global</span>
                </div>
                <div class="cf-chart-wrap short">
                  <canvas id="chart-lsr" phx-hook="ChartJSPanel" data-preset="line"></canvas>
                </div>
              </div>

              <%!-- Funding --%>
              <div class="cf-panel">
                <div class="cf-ind-head">
                  <span>Funding Rate · 8h cycle</span>
                </div>
                <div class="cf-chart-wrap short">
                  <canvas id="chart-funding" phx-hook="ChartJSPanel" data-preset="bar"></canvas>
                </div>
              </div>
            </div>
          </div>

          <%!-- ── right rail: hunter matrix + level gauge + signal feed ── --%>
          <aside class="space-y-3">
            <%!-- Hunter matrix --%>
            <div class="cf-panel">
              <div class="cf-panel-head">
                <span class="title"><span class="marker"></span>Smart Money Hunter</span>
                <span class="cf-pill muted">{@symbol}</span>
              </div>
              <div class="cf-panel-body">
                <table class="cf-matrix w-full">
                  <thead>
                    <tr>
                      <th>tf</th>
                      <th :for={row <- @hunter}>{row.interval}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr>
                      <th>EXP</th>
                      <td :for={row <- @hunter} class={"lvl-" <> Integer.to_string(row.exp_level)}>{row.exp_level}</td>
                    </tr>
                    <tr>
                      <th>RSI</th>
                      <td :for={row <- @hunter} class={"lvl-" <> Integer.to_string(row.rsi_level)}>{row.rsi_level}</td>
                    </tr>
                    <tr>
                      <th>VOL</th>
                      <td :for={row <- @hunter} class={"lvl-" <> Integer.to_string(row.vol_level)}>{row.vol_level}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>

            <%!-- Level gauge --%>
            <div class="cf-gauge">
              <span class="label">Level</span>
              <span class="value">{Float.round(@level_pct / 100 * 6, 1)}</span>
              <div class="bar grow">
                <div class="bar-fill" style={"--gauge-pct: " <> Float.to_string(@level_pct) <> "%"}></div>
              </div>
            </div>

            <%!-- Recent signals --%>
            <div class="cf-panel">
              <div class="cf-panel-head">
                <span class="title"><span class="marker short"></span>Signals on {@symbol}</span>
                <a href="/signals" class="cf-pill muted">all</a>
              </div>
              <div class="cf-panel-body" style="padding: 0; max-height: 360px; overflow-y: auto;">
                <div :if={@signals == []} class="text-center py-6" style="color: var(--ink-3); font-size: 11px;">
                  No signals on this symbol yet.
                </div>
                <div :for={s <- @signals} class="px-3 py-2 mono" style="border-bottom: 1px solid var(--line); font-size: 11px;">
                  <div class="flex justify-between items-center">
                    <span class="cf-pill" style={side_pill_style(s.side)}>{String.upcase(s.side)}</span>
                    <span style="color: var(--ink-3);">{Calendar.strftime(s.generated_at, "%H:%M:%S")}</span>
                  </div>
                  <div class="mt-1" style="color: var(--ink-2);">
                    @ <span style="color: var(--ink); font-weight: 600;">{s.price}</span>
                    · score=<span style="color: var(--ink);">{format_score(s.score)}</span>
                  </div>
                </div>
              </div>
            </div>

            <a href={~p"/settings/#{@symbol}"} class="cf-btn w-full justify-center">
              <.icon name="hero-cog-6-tooth-mini" class="size-4" /> Tune Strategy
            </a>
          </aside>
        </section>
      </div>
    </Layouts.shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :highlight, :boolean, default: false

  defp ticker_cell(assigns) do
    ~H"""
    <div class="px-4 py-3" style="border-color: var(--line);">
      <div style="font-size: 9px; letter-spacing: 0.12em; text-transform: uppercase; color: var(--ink-3);">{@label}</div>
      <div class={"mono " <> if(@highlight, do: "font-bold", else: "")} style={"font-size: 14px; color: " <> if(@highlight, do: "var(--ink)", else: "var(--ink-2)")}>
        {@value}
      </div>
    </div>
    """
  end

  # ── view-helper functions ──────────────────────────────────

  defp last_close([]), do: "—"
  defp last_close(candles), do: candles |> List.last() |> Map.get(:close, "—")

  defp last_trades([]), do: 0

  defp last_trades(candles) do
    case List.last(candles) do
      %{trades: t} -> t
      _ -> 0
    end
  end

  defp latest_oi(symbol) do
    Repo.one(from o in OpenInterest, where: o.symbol == ^symbol, order_by: [desc: o.time], limit: 1)
    |> case do
      nil -> nil
      o -> o.open_interest
    end
  end

  defp latest_ema(candles, period) do
    closes = Enum.filter(candles, & &1.closed) |> Enum.map(& &1.close)
    EMA.last(closes, period)
  end

  defp latest_rsi(candles) do
    closes = Enum.filter(candles, & &1.closed) |> Enum.map(& &1.close)
    RSI.last(closes, 14)
  end

  defp lsr_rsi(symbol) do
    series =
      Repo.all(
        from l in LongShortRatio,
          where: l.symbol == ^symbol and l.source == "global_account",
          order_by: [desc: l.time],
          limit: 30
      )
      |> Enum.reverse()

    case LSRSignal.calculate(series) do
      %{rsi: rsi} -> rsi
      _ -> nil
    end
  end

  defp format_num(nil), do: "—"
  defp format_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_num(n) when is_integer(n), do: Integer.to_string(n)
  defp format_num(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 4), :normal)
  defp format_num(other), do: to_string(other)

  defp format_score(nil), do: "—"
  defp format_score(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_score(n), do: to_string(n)

  defp side_pill_style("long"), do: "background: var(--long-bg); color: var(--long);"
  defp side_pill_style("short"), do: "background: var(--short-bg); color: var(--short);"
  defp side_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp rsi_color(nil), do: "var(--ink-3)"

  defp rsi_color(rsi) when is_number(rsi) do
    cond do
      rsi >= 70 -> "var(--short)"
      rsi <= 30 -> "var(--long)"
      true -> "var(--ink)"
    end
  end

  defp rsi_color(_), do: "var(--ink-3)"
end

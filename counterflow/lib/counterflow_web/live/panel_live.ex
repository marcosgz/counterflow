defmodule CounterflowWeb.PanelLive do
  @moduledoc """
  Dense per-symbol panel à la Encryptos / Coinalyze. One row per watchlist
  symbol; columns:

    #  Symbol  Price  24h%  OI(5m)  OI▼  LSR(5m)  LSR▼  FR(5m)  Trades 1d
    RSI {1d 4h 1h 30m 15m 5m 1m}  EXP {1d 4h 1h 30m 15m 5m 1m}

  RSI cells are shaded by value (red overbought, green oversold). EXP
  cells (Trade-Force level mapped to 0..6) use the same 0/grey · 1/cyan ·
  2/amber · 3/rose · 5/green · 6/magenta palette as the indicator panels.

  Refresh: every 30s via :timer.send_interval. Manual refresh button.
  """

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias CounterflowWeb.Layouts
  alias Counterflow.{Repo, Watchlist}
  alias Counterflow.Indicators.{BucketedForce, RSI}
  alias Counterflow.Market.{Candle, OpenInterest, LongShortRatio, FundingRate}

  @intervals ["1d", "4h", "1h", "30m", "15m", "5m", "1m"]
  @history 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(30_000, :refresh)

    {:ok,
     socket
     |> assign(:current_path, "/")
     |> assign(:intervals, @intervals)
     |> assign(:loading?, true)
     |> assign(:rows, [])
     |> assign(:last_loaded_at, nil)
     |> tap(fn s -> if connected?(s), do: send(self(), :load) end)}
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, do_load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, do_load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, do_load(socket)}

  defp do_load(socket) do
    symbols = watchlist_symbols()
    rows = build_rows(symbols)

    socket
    |> assign(:rows, rows)
    |> assign(:loading?, false)
    |> assign(:last_loaded_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp watchlist_symbols do
    Watchlist.all()
    |> Enum.map(& &1.symbol)
    |> Enum.sort()
  end

  defp build_rows([]), do: []

  defp build_rows(symbols) do
    oi_map = latest_oi_map(symbols)
    lsr_map = latest_lsr_map(symbols)
    funding_map = latest_funding_map(symbols)
    daily_map = daily_change_map(symbols)
    trades_map = trades_1d_map(symbols)

    rsi_exp_map =
      symbols
      |> Task.async_stream(&{&1, rsi_exp_for_symbol(&1)},
        max_concurrency: 8,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {sym, data}} -> {sym, data}
        _ -> {nil, %{}}
      end)
      |> Enum.reject(&match?({nil, _}, &1))
      |> Map.new()

    symbols
    |> Enum.with_index(1)
    |> Enum.map(fn {symbol, idx} ->
      daily = Map.get(daily_map, symbol, %{price: nil, change_pct: nil})
      oi = Map.get(oi_map, symbol, %{value: nil, trend: :flat})
      lsr = Map.get(lsr_map, symbol, %{value: nil, trend: :flat})

      %{
        idx: idx,
        symbol: symbol,
        price: daily.price,
        change_pct: daily.change_pct,
        oi: oi.value,
        oi_trend: oi.trend,
        lsr: lsr.value,
        lsr_trend: lsr.trend,
        fr: Map.get(funding_map, symbol),
        trades_1d: Map.get(trades_map, symbol, 0),
        rsi: Map.get(rsi_exp_map, symbol, %{}).rsi || %{},
        exp: Map.get(rsi_exp_map, symbol, %{}).exp || %{}
      }
    end)
  end

  # ── batch queries ──────────────────────────────────────────

  defp latest_oi_map(symbols) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    rows =
      Repo.all(
        from o in OpenInterest,
          where: o.symbol in ^symbols and o.time > ^cutoff,
          order_by: [asc: o.symbol, desc: o.time]
      )

    rows
    |> Enum.group_by(& &1.symbol)
    |> Map.new(fn {sym, list} ->
      [latest | rest] = list
      prev = List.first(rest)

      trend =
        cond do
          is_nil(prev) -> :flat
          Decimal.gt?(latest.open_interest, prev.open_interest) -> :up
          Decimal.lt?(latest.open_interest, prev.open_interest) -> :down
          true -> :flat
        end

      {sym, %{value: latest.open_interest, trend: trend}}
    end)
  end

  defp latest_lsr_map(symbols) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    rows =
      Repo.all(
        from l in LongShortRatio,
          where:
            l.symbol in ^symbols and l.source == "global_account" and l.time > ^cutoff,
          order_by: [asc: l.symbol, desc: l.time]
      )

    rows
    |> Enum.group_by(& &1.symbol)
    |> Map.new(fn {sym, list} ->
      [latest | rest] = list
      prev = List.first(rest)

      trend =
        cond do
          is_nil(prev) -> :flat
          Decimal.gt?(latest.ls_ratio, prev.ls_ratio) -> :up
          Decimal.lt?(latest.ls_ratio, prev.ls_ratio) -> :down
          true -> :flat
        end

      {sym, %{value: latest.ls_ratio, trend: trend}}
    end)
  end

  defp latest_funding_map(symbols) do
    cutoff = DateTime.add(DateTime.utc_now(), -120, :second)

    Repo.all(
      from f in FundingRate,
        where: f.symbol in ^symbols and f.time > ^cutoff,
        distinct: f.symbol,
        order_by: [asc: f.symbol, desc: f.time],
        select: {f.symbol, f.funding_rate}
    )
    |> Map.new()
  end

  defp daily_change_map(symbols) do
    one_day_ago = DateTime.add(DateTime.utc_now(), -86_400, :second)

    rows =
      Repo.all(
        from c in Candle,
          where: c.symbol in ^symbols and c.interval == "1h" and c.time > ^one_day_ago and c.closed == true,
          order_by: [asc: c.symbol, asc: c.time]
      )

    rows
    |> Enum.group_by(& &1.symbol)
    |> Map.new(fn {sym, list} ->
      first = List.first(list)
      last = List.last(list)

      change =
        if first && last && Decimal.gt?(first.open, 0) do
          diff = Decimal.sub(last.close, first.open)
          Decimal.div(diff, first.open) |> Decimal.to_float()
        else
          nil
        end

      {sym, %{price: last && last.close, change_pct: change}}
    end)
  end

  defp trades_1d_map(symbols) do
    one_day_ago = DateTime.add(DateTime.utc_now(), -86_400, :second)

    Repo.all(
      from c in Candle,
        where: c.symbol in ^symbols and c.interval == "1m" and c.time > ^one_day_ago and c.closed == true,
        group_by: c.symbol,
        select: {c.symbol, sum(c.trades)}
    )
    |> Map.new(fn {sym, n} -> {sym, n || 0} end)
  end

  # ── per-symbol RSI + EXP (TF level) across all intervals ──

  defp rsi_exp_for_symbol(symbol) do
    Enum.reduce(@intervals, %{rsi: %{}, exp: %{}}, fn interval, acc ->
      candles = load_candles(symbol, interval)

      rsi =
        if length(candles) >= 15 do
          closes = Enum.map(candles, & &1.close)
          RSI.last(closes, 14)
        end

      exp_level =
        if candles == [] do
          0
        else
          BucketedForce.calculate(candles, &BucketedForce.trades_extractor/1).level
        end

      %{
        rsi: Map.put(acc.rsi, interval, rsi),
        exp: Map.put(acc.exp, interval, exp_level)
      }
    end)
  end

  defp load_candles(symbol, interval) do
    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^symbol and c.interval == ^interval and c.closed == true,
        order_by: [desc: c.time],
        limit: @history
    )
    |> Enum.reverse()
  end

  # ── view ────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-4 w-full space-y-3">
        <header class="flex items-center justify-between flex-wrap gap-2">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">
            PANEL · TIMEFRAME
          </h1>
          <div class="flex items-center gap-2 mono" style="font-size: 11px; color: var(--ink-3);">
            <span :if={@last_loaded_at}>
              loaded {Calendar.strftime(@last_loaded_at, "%H:%M:%S")} UTC
            </span>
            <span :if={@loading?}>loading…</span>
            <button phx-click="refresh" class="cf-btn">Refresh</button>
          </div>
        </header>

        <div class="cf-panel" style="overflow-x: auto;">
          <table class="cf-panel-table">
            <thead>
              <tr>
                <th rowspan="2">#</th>
                <th rowspan="2" style="text-align: left;">Symbol</th>
                <th rowspan="2" class="num">Price</th>
                <th rowspan="2" class="num">24h%</th>
                <th rowspan="2" class="num">OI 5m</th>
                <th rowspan="2"></th>
                <th rowspan="2" class="num">LSR 5m</th>
                <th rowspan="2"></th>
                <th rowspan="2" class="num">FR 5m</th>
                <th rowspan="2" class="num">Trades 1d</th>
                <th colspan={length(@intervals)} class="grp">RSI</th>
                <th colspan={length(@intervals)} class="grp">EXP</th>
              </tr>
              <tr>
                <th :for={i <- @intervals} class="num sub">{i}</th>
                <th :for={i <- @intervals} class="num sub">{i}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- @rows}>
                <td class="num idx">{r.idx}</td>
                <td>
                  <a href={~p"/symbol/#{r.symbol}"} style="color: var(--ink); font-weight: 600;">
                    {r.symbol}
                  </a>
                </td>
                <td class="num">{format_price(r.price)}</td>
                <td class="num" style={pct_color(r.change_pct)}>{format_pct(r.change_pct)}</td>
                <td class="num">{format_oi(r.oi)}</td>
                <td class="num">{trend_arrow(r.oi_trend)}</td>
                <td class="num">{format_lsr(r.lsr)}</td>
                <td class="num">{trend_arrow(r.lsr_trend)}</td>
                <td class="num" style={fr_color(r.fr)}>{format_fr(r.fr)}</td>
                <td class="num" style="color: var(--ink-3);">{format_int(r.trades_1d)}</td>
                <td :for={i <- @intervals} class="num cell" style={rsi_cell_style(Map.get(r.rsi, i))}>
                  {format_rsi(Map.get(r.rsi, i))}
                </td>
                <td :for={i <- @intervals} class="num cell" style={exp_cell_style(Map.get(r.exp, i))}>
                  {Map.get(r.exp, i)}
                </td>
              </tr>
              <tr :if={@rows == []}>
                <td colspan="20" class="text-center py-8" style="color: var(--ink-3);">
                  <%= if @loading?, do: "Loading…", else: "Add symbols to your watchlist to populate the panel." %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p class="mono" style="color: var(--ink-mute); font-size: 10px;">
          RSI shaded by overbought (&gt;70 red) / oversold (&lt;30 green). EXP cells use the legacy
          0/1/2/3/5/6 trade-force palette. Click a symbol for the full chart + indicator panels.
        </p>
      </div>
    </Layouts.shell>
    """
  end

  # ── view-helper functions ─────────────────────────────────

  defp format_price(nil), do: "—"
  defp format_price(%Decimal{} = d), do: d |> Decimal.round(4) |> Decimal.to_string(:normal)
  defp format_price(other), do: to_string(other)

  defp format_pct(nil), do: "—"
  defp format_pct(n) when is_number(n), do: "#{Float.round(n * 100, 2)}%"

  defp pct_color(n) when is_number(n) and n > 0, do: "color: var(--long);"
  defp pct_color(n) when is_number(n) and n < 0, do: "color: var(--short);"
  defp pct_color(_), do: "color: var(--ink-3);"

  defp format_oi(nil), do: "—"

  defp format_oi(%Decimal{} = d) do
    n = Decimal.to_float(d)

    cond do
      n >= 1_000_000_000 -> "#{Float.round(n / 1_000_000_000, 2)}B"
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 2)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 1)}K"
      true -> "#{Float.round(n, 0)}"
    end
  end

  defp format_lsr(nil), do: "—"
  defp format_lsr(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp format_fr(nil), do: "—"

  defp format_fr(%Decimal{} = d) do
    pct = Decimal.mult(d, Decimal.new(10_000)) |> Decimal.round(0)
    "#{Decimal.to_string(pct, :normal)}bps"
  end

  defp fr_color(nil), do: ""

  defp fr_color(%Decimal{} = d) do
    cond do
      Decimal.compare(d, Decimal.new(0)) == :gt -> "color: var(--short);"
      Decimal.compare(d, Decimal.new(0)) == :lt -> "color: var(--long);"
      true -> "color: var(--ink-3);"
    end
  end

  defp format_int(nil), do: "—"

  defp format_int(n) when is_integer(n) do
    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 1)}K"
      true -> Integer.to_string(n)
    end
  end

  defp trend_arrow(:up), do: Phoenix.HTML.raw(~S|<span style="color: var(--long);">▲</span>|)
  defp trend_arrow(:down), do: Phoenix.HTML.raw(~S|<span style="color: var(--short);">▼</span>|)
  defp trend_arrow(_), do: Phoenix.HTML.raw(~S|<span style="color: var(--ink-mute);">·</span>|)

  defp format_rsi(nil), do: ""
  defp format_rsi(n) when is_number(n), do: :erlang.float_to_binary(n, decimals: 0)

  defp rsi_cell_style(nil), do: ""

  defp rsi_cell_style(rsi) when is_number(rsi) do
    cond do
      rsi >= 80 -> "background: rgba(244,63,94,0.55); color: var(--bg);"
      rsi >= 70 -> "background: rgba(244,63,94,0.30); color: var(--ink);"
      rsi >= 60 -> "background: rgba(34,197,94,0.30); color: var(--ink);"
      rsi >= 40 -> "background: rgba(34,197,94,0.10);"
      rsi >= 30 -> "background: rgba(34,211,238,0.20);"
      rsi >= 20 -> "background: rgba(34,211,238,0.40); color: var(--ink);"
      true -> "background: rgba(34,211,238,0.60); color: var(--bg);"
    end
  end

  defp exp_cell_style(nil), do: ""
  defp exp_cell_style(0), do: "background: rgba(140,140,150,0.10); color: var(--ink-3);"
  defp exp_cell_style(1), do: "background: rgba(34,211,238,0.40); color: var(--ink);"
  defp exp_cell_style(2), do: "background: rgba(245,158,11,0.45); color: var(--bg);"
  defp exp_cell_style(3), do: "background: rgba(244,63,94,0.55); color: var(--bg);"
  defp exp_cell_style(4), do: "background: rgba(34,211,238,0.60); color: var(--bg);"
  defp exp_cell_style(5), do: "background: rgba(34,197,94,0.65); color: var(--bg); font-weight: 700;"
  defp exp_cell_style(6), do: "background: rgba(217,70,239,0.85); color: var(--bg); font-weight: 700;"
  defp exp_cell_style(_), do: ""
end

defmodule CounterflowWeb.SettingsLive do
  @moduledoc "Per-symbol strategy config editor — trader-grade form layout."

  use CounterflowWeb, :live_view

  alias CounterflowWeb.Layouts
  alias Counterflow.Strategy.Config
  alias Counterflow.Watchlist

  @impl true
  def mount(%{"symbol" => symbol}, _session, socket) do
    cfg = Config.for(symbol)

    {:ok,
     socket
     |> assign(:current_path, "/settings/#{symbol}")
     |> assign(:symbol, symbol)
     |> assign(:cfg, cfg)
     |> assign(:saved, false)}
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/settings")
     |> assign(:watchlist, Watchlist.all())}
  end

  @impl true
  def handle_event("save", %{"cfg" => params}, socket) do
    attrs = %{
      enabled: cast_bool(params["enabled"]),
      interval: params["interval"],
      threshold: cast_decimal(params["threshold"]),
      trend_profile: cast_int(params["trend_profile"]),
      cooldown_minutes: cast_int(params["cooldown_minutes"]),
      max_leverage: cast_int(params["max_leverage"]),
      min_tf_level: cast_int(params["min_tf_level"]),
      sides_enabled: %{
        "long" => cast_bool(params["enable_long"]),
        "short" => cast_bool(params["enable_short"])
      },
      enable_alerts: cast_bool(params["enable_alerts"]),
      enable_paper: cast_bool(params["enable_paper"]),
      enable_live: cast_bool(params["enable_live"])
    }

    case Config.upsert(socket.assigns.symbol, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:cfg, Config.for(socket.assigns.symbol))
         |> assign(:saved, true)}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Failed to save config")}
    end
  end

  defp cast_bool("true"), do: true
  defp cast_bool("on"), do: true
  defp cast_bool(true), do: true
  defp cast_bool(_), do: false

  defp cast_int(""), do: nil
  defp cast_int(nil), do: nil
  defp cast_int(s) when is_binary(s), do: String.to_integer(s)
  defp cast_int(n) when is_integer(n), do: n

  defp cast_decimal(""), do: nil
  defp cast_decimal(nil), do: nil
  defp cast_decimal(s) when is_binary(s), do: Decimal.new(s)
  defp cast_decimal(%Decimal{} = d), do: d

  @impl true
  def render(%{symbol: _} = assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path} symbol={@symbol}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">
            STRATEGY · <span class="mono" style="color: var(--long);">{@symbol}</span>
          </h1>
          <a href={~p"/symbol/#{@symbol}"} class="cf-pill muted">view chart →</a>
        </header>

        <div :if={@saved} class="cf-panel" style="border-color: var(--long);">
          <div class="cf-panel-body" style="padding: 10px 14px; color: var(--long); font-size: 11px;">
            ✓ Saved · effective on next candle close.
          </div>
        </div>

        <form phx-submit="save" class="space-y-3">
          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker"></span>Strategy Engine</span>
            </div>
            <div class="cf-panel-body space-y-0">
              <div class="cf-form-row">
                <div class="label">Enabled</div>
                <label class="flex items-center gap-2 mono" style="font-size: 11px; color: var(--ink-2);">
                  <input type="checkbox" name="cfg[enabled]" checked={@cfg.enabled} value="true" />
                  Strategy fires for this symbol
                </label>
              </div>

              <div class="cf-form-row">
                <div class="label">Interval</div>
                <select name="cfg[interval]" class="cf-select w-32">
                  <option :for={i <- ["1m", "5m", "15m", "1h", "4h"]} selected={@cfg.interval == i}>{i}</option>
                </select>
              </div>

              <div class="cf-form-row">
                <div class="label">Threshold (0..1)</div>
                <input type="number" step="0.01" min="0" max="1" name="cfg[threshold]"
                       value={threshold_str(@cfg.threshold)} class="cf-input w-32" />
              </div>

              <div class="cf-form-row">
                <div class="label">Trend Profile</div>
                <select name="cfg[trend_profile]" class="cf-select w-44">
                  <option value={1} selected={@cfg.trend_profile == 1}>1 · strict</option>
                  <option value={2} selected={@cfg.trend_profile == 2}>2 · default</option>
                  <option value={3} selected={@cfg.trend_profile == 3}>3 · loose</option>
                </select>
              </div>

              <div class="cf-form-row">
                <div class="label">Min TF level</div>
                <input type="number" min="0" max="6" name="cfg[min_tf_level]"
                       value={@cfg.min_tf_level} class="cf-input w-24" />
              </div>

              <div class="cf-form-row">
                <div class="label">Cooldown · minutes</div>
                <input type="number" min="0" name="cfg[cooldown_minutes]"
                       value={@cfg.cooldown_minutes} class="cf-input w-24" />
              </div>

              <div class="cf-form-row">
                <div class="label">Max leverage</div>
                <input type="number" min="1" max="10" name="cfg[max_leverage]"
                       value={@cfg.max_leverage} class="cf-input w-24" />
              </div>
            </div>
          </div>

          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker warn"></span>Sides</span>
            </div>
            <div class="cf-panel-body flex gap-6 mono" style="font-size: 11px; color: var(--ink-2);">
              <label class="flex items-center gap-2">
                <input type="checkbox" name="cfg[enable_long]" value="true"
                       checked={Map.get(@cfg.sides_enabled, "long", true)} />
                <span class="cf-pill" style="background: var(--long-bg); color: var(--long);">LONG</span>
              </label>
              <label class="flex items-center gap-2">
                <input type="checkbox" name="cfg[enable_short]" value="true"
                       checked={Map.get(@cfg.sides_enabled, "short", true)} />
                <span class="cf-pill" style="background: var(--short-bg); color: var(--short);">SHORT</span>
              </label>
            </div>
          </div>

          <div class="cf-panel cf-panel-flush">
            <div class="cf-panel-head">
              <span class="title"><span class="marker short"></span>Outputs</span>
              <span class="cf-pill muted">layered</span>
            </div>
            <div class="cf-panel-body space-y-2 mono" style="font-size: 11px; color: var(--ink-2);">
              <label class="flex items-center gap-2">
                <input type="checkbox" name="cfg[enable_alerts]" value="true" checked={@cfg.enable_alerts} />
                Alerts (PubSub + sinks)
              </label>
              <label class="flex items-center gap-2">
                <input type="checkbox" name="cfg[enable_paper]" value="true" checked={@cfg.enable_paper} />
                Auto paper-trade
              </label>
              <label class="flex items-center gap-2 opacity-60">
                <input type="checkbox" name="cfg[enable_live]" value="true" checked={@cfg.enable_live} disabled />
                Live trading <span class="cf-pill muted">gated · phase 8b</span>
              </label>
            </div>
          </div>

          <div class="flex justify-end">
            <button type="submit" class="cf-btn primary">Save</button>
          </div>
        </form>
      </div>
    </Layouts.shell>
    """
  end

  def render(%{watchlist: _} = assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">SETTINGS</h1>
          <span class="cf-pill muted">per-symbol</span>
        </header>

        <p class="mono" style="color: var(--ink-3); font-size: 11px;">
          Pick a symbol to tune its strategy thresholds, sides, and outputs.
        </p>

        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-2">
          <a :for={w <- @watchlist} href={~p"/settings/#{w.symbol}"} class="cf-heat">
            <div class="sym">{w.symbol}</div>
            <div class="pct">tune →</div>
          </a>
          <div :if={@watchlist == []} class="col-span-full text-center py-6" style="color: var(--ink-3);">
            <a href="/watchlist" style="color: var(--ink); text-decoration: underline;">Add symbols</a> to your watchlist first.
          </div>
        </div>
      </div>
    </Layouts.shell>
    """
  end

  defp threshold_str(nil), do: ""
  defp threshold_str(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp threshold_str(n) when is_number(n), do: to_string(n)
end

defmodule CounterflowWeb.SettingsLive do
  @moduledoc """
  Per-symbol strategy config editor. Reads + writes
  `Counterflow.Strategy.Config` rows.
  """

  use CounterflowWeb, :live_view

  alias Counterflow.Strategy.Config
  alias Counterflow.Watchlist

  @impl true
  def mount(%{"symbol" => symbol}, _session, socket) do
    cfg = Config.for(symbol)

    {:ok,
     socket
     |> assign(:symbol, symbol)
     |> assign(:cfg, cfg)
     |> assign(:saved, false)}
  end

  def mount(_params, _session, socket) do
    watchlist = Watchlist.all()
    {:ok, assign(socket, :watchlist, watchlist)}
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
    <div class="p-6 max-w-3xl mx-auto space-y-4">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-bold">
          Settings · <span class="font-mono">{@symbol}</span>
        </h1>
        <nav class="text-sm space-x-4">
          <.link navigate={~p"/symbol/#{@symbol}"} class="underline">Chart</.link>
          <.link navigate={~p"/settings"} class="underline">All symbols</.link>
        </nav>
      </header>

      <div :if={@saved} class="bg-emerald-100 dark:bg-emerald-900/30 px-3 py-2 rounded text-sm">
        Saved.
      </div>

      <form phx-submit="save" class="space-y-4 text-sm">
        <fieldset class="border rounded p-4">
          <legend class="px-2 font-semibold">Enabled</legend>
          <label class="flex items-center gap-2">
            <input type="checkbox" name="cfg[enabled]" checked={@cfg.enabled} value="true" />
            Strategy enabled for this symbol
          </label>
        </fieldset>

        <fieldset class="border rounded p-4 grid grid-cols-2 gap-3">
          <legend class="px-2 font-semibold">Strategy</legend>

          <label>
            Interval
            <select name="cfg[interval]" class="border rounded px-2 py-1 ml-1">
              <option :for={i <- ["1m", "5m", "15m", "1h", "4h"]} selected={@cfg.interval == i}>{i}</option>
            </select>
          </label>

          <label>
            Threshold (0..1)
            <input type="number" step="0.01" min="0" max="1" name="cfg[threshold]"
                   value={threshold_str(@cfg.threshold)} class="border rounded px-2 py-1 ml-1 w-20" />
          </label>

          <label>
            Trend profile
            <select name="cfg[trend_profile]" class="border rounded px-2 py-1 ml-1">
              <option :for={p <- 1..3} value={p} selected={@cfg.trend_profile == p}>
                {p} ({profile_label(p)})
              </option>
            </select>
          </label>

          <label>
            Min TF level
            <input type="number" min="0" max="6" name="cfg[min_tf_level]"
                   value={@cfg.min_tf_level} class="border rounded px-2 py-1 ml-1 w-16" />
          </label>

          <label>
            Cooldown (minutes)
            <input type="number" min="0" name="cfg[cooldown_minutes]"
                   value={@cfg.cooldown_minutes} class="border rounded px-2 py-1 ml-1 w-20" />
          </label>

          <label>
            Max leverage (1..10)
            <input type="number" min="1" max="10" name="cfg[max_leverage]"
                   value={@cfg.max_leverage} class="border rounded px-2 py-1 ml-1 w-16" />
          </label>
        </fieldset>

        <fieldset class="border rounded p-4 flex gap-6">
          <legend class="px-2 font-semibold">Sides</legend>
          <label class="flex items-center gap-2">
            <input type="checkbox" name="cfg[enable_long]" value="true"
                   checked={Map.get(@cfg.sides_enabled, "long", true)} /> Long
          </label>
          <label class="flex items-center gap-2">
            <input type="checkbox" name="cfg[enable_short]" value="true"
                   checked={Map.get(@cfg.sides_enabled, "short", true)} /> Short
          </label>
        </fieldset>

        <fieldset class="border rounded p-4 flex flex-col gap-2">
          <legend class="px-2 font-semibold">Outputs</legend>
          <label class="flex items-center gap-2">
            <input type="checkbox" name="cfg[enable_alerts]" value="true" checked={@cfg.enable_alerts} />
            Send alerts (Telegram / Discord / desktop sinks)
          </label>
          <label class="flex items-center gap-2">
            <input type="checkbox" name="cfg[enable_paper]" value="true" checked={@cfg.enable_paper} />
            Auto paper-trade
          </label>
          <label class="flex items-center gap-2 opacity-50">
            <input type="checkbox" name="cfg[enable_live]" value="true" checked={@cfg.enable_live} disabled />
            Live trading (gated until Phase 8b)
          </label>
        </fieldset>

        <button type="submit" class="px-4 py-2 bg-emerald-600 text-white rounded">Save</button>
      </form>
    </div>
    """
  end

  def render(%{watchlist: _} = assigns) do
    ~H"""
    <div class="p-6 max-w-3xl mx-auto space-y-4">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-bold">Strategy settings</h1>
        <nav class="text-sm space-x-4">
          <.link navigate={~p"/"} class="underline">Overview</.link>
          <.link navigate={~p"/watchlist"} class="underline">Watchlist</.link>
        </nav>
      </header>

      <p class="text-sm text-gray-600 dark:text-gray-400">
        Pick a symbol from your watchlist to edit its strategy config.
      </p>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
        <.link
          :for={w <- @watchlist}
          navigate={~p"/settings/#{w.symbol}"}
          class="block p-3 rounded border text-center font-mono hover:bg-gray-50 dark:hover:bg-gray-800"
        >
          {w.symbol}
        </.link>
      </div>
    </div>
    """
  end

  defp threshold_str(nil), do: ""
  defp threshold_str(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp threshold_str(n) when is_number(n), do: to_string(n)

  defp profile_label(1), do: "strict"
  defp profile_label(2), do: "default"
  defp profile_label(3), do: "loose"
end

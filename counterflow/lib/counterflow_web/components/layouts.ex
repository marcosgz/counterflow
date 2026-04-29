defmodule CounterflowWeb.Layouts do
  @moduledoc """
  Layout components shared across LiveViews. Defines a single `shell/1`
  component that owns the chrome (left rail, top bar, status strip) so
  each page only declares its own content area.
  """

  use CounterflowWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, default: %{}
  attr :current_path, :string, default: "/"
  attr :symbol, :string, default: nil
  attr :ws_status, :atom, default: :ok
  slot :inner_block, required: true

  @doc """
  Persistent application chrome. Renders:

    * left icon rail with primary navigation,
    * top bar with breadcrumb / brand / theme toggle,
    * scrollable main pane (the slot),
    * bottom status strip with clock + ws health.
  """
  def shell(assigns) do
    ~H"""
    <div class="cf-app">
      <aside class="cf-rail">
        <a class="cf-rail-link" href="/" title="Counterflow"
           style="background: var(--bg); color: var(--ink); margin-bottom: 4px;">
          <span class="mono" style="font-weight: 700; font-size: 14px;">C</span>
        </a>
        <.rail_link current={@current_path} href="/" icon="hero-squares-2x2-mini" label="Overview" />
        <.rail_link current={@current_path} href="/watchlist" icon="hero-rectangle-stack-mini" label="Watchlist" />
        <.rail_link current={@current_path} href="/signals" icon="hero-bolt-mini" label="Signals" />
        <.rail_link current={@current_path} href="/paper" icon="hero-banknotes-mini" label="Paper" />
        <.rail_link current={@current_path} href="/backtest" icon="hero-clock-mini" label="Backtest" />
        <.rail_link current={@current_path} href="/audit" icon="hero-document-text-mini" label="Audit log" />
        <.rail_link current={@current_path} href="/debug" icon="hero-bug-ant-mini" label="Strategy debug" />
        <div class="grow"></div>
        <.rail_link current={@current_path} href="/settings" icon="hero-cog-6-tooth-mini" label="Settings" />
      </aside>

      <header class="cf-topbar">
        <span class="brand"><span class="dot"></span>COUNTERFLOW</span>

        <div class="hidden md:flex items-center gap-2 mono" style="font-size: 11px;">
          <span class="crumb">{section_label(@current_path)}</span>
          <span :if={@symbol} class="crumb-sep">/</span>
          <span :if={@symbol} class="crumb" style="color: var(--ink);">{@symbol}</span>
        </div>

        <div class="grow"></div>

        <div class="hidden sm:flex items-center gap-3 mono" style="font-size: 11px;">
          <span style="color: var(--ink-3);">WS</span>
          <span class={ws_class(@ws_status)}>{ws_label(@ws_status)}</span>
        </div>

        <.theme_toggle />
      </header>

      <main class="cf-main">
        {render_slot(@inner_block)}
      </main>

      <footer class="cf-status">
        <div class="flex items-center gap-4">
          <span>v0.1 · phase 8</span>
          <span class="hidden md:inline">elixir {System.version()} · otp {:erlang.system_info(:otp_release)}</span>
        </div>
        <div id="status-clock" phx-hook="StatusClock" class="ok mono">--:--:-- UTC</div>
      </footer>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :current, :string, default: "/"
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp rail_link(assigns) do
    ~H"""
    <a href={@href} title={@label}
       class={"cf-rail-link" <> if(active?(@current, @href), do: " active", else: "")}>
      <.icon name={@icon} class="size-5" />
    </a>
    """
  end

  defp active?("/", "/"), do: true
  defp active?(_, "/"), do: false
  defp active?(current, href), do: String.starts_with?(current, href)

  defp section_label("/"), do: "OVERVIEW"
  defp section_label("/watchlist"), do: "WATCHLIST"
  defp section_label("/signals" <> _), do: "SIGNALS"
  defp section_label("/symbol/" <> _), do: "SYMBOL"
  defp section_label("/settings" <> _), do: "SETTINGS"
  defp section_label("/paper"), do: "PAPER"
  defp section_label("/debug"), do: "DEBUG"
  defp section_label("/backtest"), do: "BACKTEST"
  defp section_label("/audit"), do: "AUDIT"
  defp section_label(_), do: ""

  defp ws_class(:ok), do: "ok"
  defp ws_class(:warn), do: "warn"
  defp ws_class(_), do: "err"
  defp ws_label(:ok), do: "LIVE"
  defp ws_label(:warn), do: "DEGRADED"
  defp ws_label(_), do: "OFFLINE"

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="cf-flash-stack">
      <.cf_flash :if={Phoenix.Flash.get(@flash, :info)} kind={:info} message={Phoenix.Flash.get(@flash, :info)} />
      <.cf_flash :if={Phoenix.Flash.get(@flash, :error)} kind={:error} message={Phoenix.Flash.get(@flash, :error)} />
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :message, :string, required: true

  defp cf_flash(assigns) do
    ~H"""
    <div class={"cf-flash-toast " <> flash_class(@kind)} role="alert" phx-click={JS.hide()}>
      <span class="cf-flash-marker"></span>
      <span class="cf-flash-msg">{@message}</span>
      <button type="button" class="cf-flash-close" aria-label="Close" phx-click={JS.hide(to: "##{flash_dom_id(@kind)}")}>×</button>
    </div>
    """
  end

  defp flash_class(:info), do: "cf-flash-info"
  defp flash_class(:error), do: "cf-flash-error"
  defp flash_class(_), do: ""

  defp flash_dom_id(:info), do: "flash-info"
  defp flash_dom_id(:error), do: "flash-error"

  @doc "Three-way theme toggle: auto / light / dark."
  def theme_toggle(assigns) do
    ~H"""
    <div id="cf-theme-toggle" phx-hook="ThemeToggle" phx-update="ignore"
         class="cf-theme-toggle" role="group" aria-label="Theme">
      <button type="button" title="Auto" data-cf-theme="auto">
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>
      <button type="button" title="Light" data-cf-theme="light">
        <.icon name="hero-sun-micro" class="size-4" />
      </button>
      <button type="button" title="Dark" data-cf-theme="dark">
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end

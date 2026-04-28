defmodule CounterflowWeb.PaperLive do
  @moduledoc """
  Paper-trading dashboard. Shows current account equity, open positions,
  and recent fills produced by Counterflow.Bridge.SignalToPaper.
  """

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias CounterflowWeb.Layouts
  alias Counterflow.Repo
  alias Counterflow.Broker.{Paper, PaperAccount, PaperFill, PaperPosition}

  @account "paper-default"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/paper")
     |> assign(:account, account())
     |> assign(:positions, open_positions())
     |> assign(:fills, recent_fills())}
  end

  defp account do
    Repo.get(PaperAccount, @account) || Paper.ensure_account(@account, Decimal.new(10_000))
  end

  defp open_positions do
    Repo.all(
      from p in PaperPosition,
        where: p.account_id == ^@account and is_nil(p.closed_at),
        order_by: [desc: p.opened_at]
    )
  end

  defp recent_fills do
    Repo.all(
      from f in PaperFill,
        where: f.account_id == ^@account,
        order_by: [desc: f.filled_at],
        limit: 20
    )
  end

  defp realized_pnl do
    Repo.one(
      from p in PaperPosition,
        where: p.account_id == ^@account and not is_nil(p.closed_at),
        select: sum(p.realized_pnl)
    ) || Decimal.new(0)
  end

  @impl true
  def render(assigns) do
    pnl = realized_pnl()
    initial = if assigns.account, do: assigns.account.initial_balance, else: Decimal.new(0)

    balance =
      if assigns.account, do: assigns.account.balance, else: Decimal.new(0)

    return =
      if Decimal.compare(initial, 0) == :gt,
        do:
          Decimal.div(Decimal.sub(balance, initial), initial)
          |> Decimal.mult(Decimal.new(100))
          |> Decimal.round(2),
        else: Decimal.new(0)

    assigns = assigns |> assign(:pnl, pnl) |> assign(:return_pct, return)

    ~H"""
    <Layouts.shell flash={@flash} current_path={@current_path}>
      <div class="p-6 w-full space-y-4">
        <header class="flex items-center justify-between">
          <h1 class="cf-section-title" style="font-size: 14px; letter-spacing: 0.18em; color: var(--ink);">
            PAPER TRADING · <span class="mono" style="color: var(--ink-3);">{@account.id}</span>
          </h1>
          <span class="cf-pill muted">VIP-0 fees · 1bp slippage</span>
        </header>

        <section class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div class="cf-kpi long">
            <div class="cf-kpi-label">Balance</div>
            <div class="cf-kpi-value">${format_money(@account.balance)}</div>
            <div class="cf-kpi-sub">initial ${format_money(@account.initial_balance)}</div>
          </div>
          <div class={"cf-kpi " <> if(Decimal.gt?(@return_pct, 0), do: "long", else: "short")}>
            <div class="cf-kpi-label">Return</div>
            <div class="cf-kpi-value">{Decimal.to_string(@return_pct, :normal)}%</div>
            <div class="cf-kpi-sub">since inception</div>
          </div>
          <div class="cf-kpi">
            <div class="cf-kpi-label">Realized P&L</div>
            <div class="cf-kpi-value">${format_money(@pnl || Decimal.new(0))}</div>
            <div class="cf-kpi-sub">closed positions</div>
          </div>
          <div class="cf-kpi warn">
            <div class="cf-kpi-label">Open Positions</div>
            <div class="cf-kpi-value">{length(@positions)}</div>
            <div class="cf-kpi-sub">live</div>
          </div>
        </section>

        <section class="cf-panel">
          <div class="cf-panel-head">
            <span class="title"><span class="marker"></span>Open Positions</span>
          </div>
          <table class="cf-table">
            <thead>
              <tr>
                <th>Symbol</th>
                <th>Side</th>
                <th class="num">Qty</th>
                <th class="num">Entry</th>
                <th class="num">Realized P&L</th>
                <th class="num">Opened</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @positions}>
                <td>
                  <a href={~p"/symbol/#{p.symbol}"} style="color: var(--ink); font-weight: 600;">{p.symbol}</a>
                </td>
                <td>
                  <span class="cf-pill" style={pos_pill_style(p.side)}>{p.side}</span>
                </td>
                <td class="num">{p.qty}</td>
                <td class="num">{p.entry_avg}</td>
                <td class="num" style={pnl_color(p.realized_pnl)}>{format_money(p.realized_pnl || Decimal.new(0))}</td>
                <td class="num" style="color: var(--ink-3);">{Calendar.strftime(p.opened_at, "%m-%d %H:%M")}</td>
              </tr>
              <tr :if={@positions == []}>
                <td colspan="6" class="text-center py-6" style="color: var(--ink-3);">
                  No open positions.
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="cf-panel">
          <div class="cf-panel-head">
            <span class="title"><span class="marker short"></span>Recent Fills</span>
            <span class="cf-pill muted">last 20</span>
          </div>
          <table class="cf-table">
            <thead>
              <tr>
                <th>Time</th>
                <th>Symbol</th>
                <th>Side</th>
                <th class="num">Qty</th>
                <th class="num">Price</th>
                <th class="num">Fee</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={f <- @fills}>
                <td style="color: var(--ink-3);">{Calendar.strftime(f.filled_at, "%m-%d %H:%M:%S")}</td>
                <td>
                  <a href={~p"/symbol/#{f.symbol}"} style="color: var(--ink); font-weight: 600;">{f.symbol}</a>
                </td>
                <td>
                  <span class="cf-pill" style={fill_pill_style(f.side)}>{f.side}</span>
                </td>
                <td class="num">{f.qty}</td>
                <td class="num">{f.price}</td>
                <td class="num" style="color: var(--ink-3);">{format_money(f.fee)}</td>
              </tr>
              <tr :if={@fills == []}>
                <td colspan="6" class="text-center py-6" style="color: var(--ink-3);">
                  No fills yet — enable auto paper-trade for a symbol in Settings.
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.shell>
    """
  end

  defp format_money(nil), do: "0.00"

  defp format_money(%Decimal{} = d) do
    d |> Decimal.round(2) |> Decimal.to_string(:normal)
  end

  defp format_money(n), do: to_string(n)

  defp pos_pill_style("LONG"), do: "background: var(--long-bg); color: var(--long);"
  defp pos_pill_style("SHORT"), do: "background: var(--short-bg); color: var(--short);"
  defp pos_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp fill_pill_style("BUY"), do: "background: var(--long-bg); color: var(--long);"
  defp fill_pill_style("SELL"), do: "background: var(--short-bg); color: var(--short);"
  defp fill_pill_style(_), do: "background: var(--line); color: var(--ink-3);"

  defp pnl_color(nil), do: "color: var(--ink-3);"

  defp pnl_color(%Decimal{} = d) do
    cond do
      Decimal.gt?(d, 0) -> "color: var(--long);"
      Decimal.lt?(d, 0) -> "color: var(--short);"
      true -> "color: var(--ink-3);"
    end
  end

  defp pnl_color(_), do: "color: var(--ink-3);"
end

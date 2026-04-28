defmodule CounterflowWeb.OverviewLive do
  @moduledoc """
  Phase 5 overview: watchlist, recent signals, recent liquidations.

  All sections live-update via PubSub subscriptions; the page hydrates from
  Repo on mount and accumulates updates without re-querying.
  """

  use CounterflowWeb, :live_view

  import Ecto.Query

  alias Counterflow.{Repo, Watchlist}
  alias Counterflow.Strategy.Signal
  alias Counterflow.Market.{Liquidation, FundingRate}
  alias Phoenix.PubSub

  @recent_signals_limit 20
  @recent_liqs_limit 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(Counterflow.PubSub, "signals:new")
      PubSub.subscribe(Counterflow.PubSub, "liquidations:firehose")
    end

    socket =
      socket
      |> assign(:watchlist, Watchlist.all())
      |> stream(:signals, recent_signals(), at: 0, limit: @recent_signals_limit)
      |> stream(:liquidations, recent_liquidations(), at: 0, limit: @recent_liqs_limit)
      |> assign(:funding_top, top_funding(:positive))
      |> assign(:funding_bottom, top_funding(:negative))

    {:ok, socket}
  end

  @impl true
  def handle_info({:signal, %Signal{} = sig}, socket) do
    {:noreply, stream_insert(socket, :signals, sig, at: 0, limit: @recent_signals_limit)}
  end

  def handle_info({:liquidation, liq}, socket) do
    {:noreply, stream_insert(socket, :liquidations, liq, at: 0, limit: @recent_liqs_limit)}
  end

  defp recent_signals do
    Repo.all(from s in Signal, order_by: [desc: s.generated_at], limit: @recent_signals_limit)
  end

  defp recent_liquidations do
    Repo.all(from l in Liquidation, order_by: [desc: l.time], limit: @recent_liqs_limit)
    |> Enum.with_index()
    |> Enum.map(fn {l, i} ->
      Map.put(l, :id, "#{l.symbol}-#{DateTime.to_unix(l.time, :microsecond)}-#{i}")
    end)
  end

  defp top_funding(:positive) do
    Repo.all(
      from f in FundingRate,
        where: f.time > ago(2, "minute"),
        order_by: [desc: f.funding_rate],
        limit: 5
    )
  end

  defp top_funding(:negative) do
    Repo.all(
      from f in FundingRate,
        where: f.time > ago(2, "minute"),
        order_by: [asc: f.funding_rate],
        limit: 5
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto space-y-8">
      <header class="flex items-baseline justify-between">
        <h1 class="text-3xl font-bold">Counterflow</h1>
        <nav class="text-sm space-x-4">
          <.link navigate={~p"/watchlist"} class="underline">Watchlist</.link>
          <.link navigate={~p"/signals"} class="underline">Signals</.link>
        </nav>
      </header>

      <section>
        <h2 class="text-xl font-semibold mb-3">Watchlist ({length(@watchlist)})</h2>
        <div class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-6 gap-2">
          <.link
            :for={w <- @watchlist}
            navigate={~p"/symbol/#{w.symbol}"}
            class={[
              "block p-3 rounded border text-center font-mono",
              if(w.pinned, do: "bg-yellow-100 dark:bg-yellow-900/30", else: "")
            ]}
          >
            <div class="font-bold">{w.symbol}</div>
            <div class="text-xs text-gray-500">{w.promoted_by || "-"}</div>
          </.link>
        </div>
      </section>

      <section class="grid lg:grid-cols-2 gap-6">
        <div>
          <h2 class="text-xl font-semibold mb-3">Top Funding (longs paying)</h2>
          <table class="w-full text-sm font-mono">
            <thead>
              <tr class="text-left">
                <th>Symbol</th>
                <th class="text-right">Rate</th>
                <th class="text-right">Mark</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={f <- @funding_top} class="border-t">
                <td>{f.symbol}</td>
                <td class="text-right">{Decimal.to_string(f.funding_rate, :normal)}</td>
                <td class="text-right">{f.mark_price}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div>
          <h2 class="text-xl font-semibold mb-3">Bottom Funding (shorts paying)</h2>
          <table class="w-full text-sm font-mono">
            <thead>
              <tr class="text-left">
                <th>Symbol</th>
                <th class="text-right">Rate</th>
                <th class="text-right">Mark</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={f <- @funding_bottom} class="border-t">
                <td>{f.symbol}</td>
                <td class="text-right">{Decimal.to_string(f.funding_rate, :normal)}</td>
                <td class="text-right">{f.mark_price}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2 class="text-xl font-semibold mb-3">Recent Signals</h2>
        <div id="signals-list" phx-update="stream" class="space-y-1 text-sm font-mono">
          <div
            :for={{dom_id, sig} <- @streams.signals}
            id={dom_id}
            class={["p-2 rounded border-l-4", side_color(sig.side)]}
          >
            <span class="font-bold">{sig.symbol}</span>
            <span class="uppercase">{sig.side}</span>
            <span>@ {sig.price}</span>
            <span>score={sig.score}</span>
            <span class="text-gray-500">{Calendar.strftime(sig.generated_at, "%H:%M:%S")}</span>
          </div>
          <div :if={@streams.signals == []} class="text-gray-500">No signals yet.</div>
        </div>
      </section>

      <section>
        <h2 class="text-xl font-semibold mb-3">Recent Liquidations (firehose)</h2>
        <div id="liqs-list" phx-update="stream" class="space-y-1 text-xs font-mono">
          <div
            :for={{dom_id, l} <- @streams.liquidations}
            id={dom_id}
            class="grid grid-cols-5 gap-2 border-b py-1"
          >
            <span class="font-bold">{l.symbol}</span>
            <span class={if l.side == "SELL", do: "text-rose-500", else: "text-emerald-500"}>
              {l.side}
            </span>
            <span class="text-right">{l.price}</span>
            <span class="text-right">{l.qty}</span>
            <span class="text-right text-gray-500">{Calendar.strftime(l.time, "%H:%M:%S")}</span>
          </div>
          <div :if={@streams.liquidations == []} class="text-gray-500">Listening…</div>
        </div>
      </section>
    </div>
    """
  end

  defp side_color("long"), do: "border-emerald-500 bg-emerald-50/50 dark:bg-emerald-900/10"
  defp side_color("short"), do: "border-rose-500 bg-rose-50/50 dark:bg-rose-900/10"
  defp side_color(_), do: "border-gray-300"
end

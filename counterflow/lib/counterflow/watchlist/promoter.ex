defmodule Counterflow.Watchlist.Promoter do
  @moduledoc """
  Auto-promotes high-activity symbols into the watchlist and demotes
  long-quiet non-pinned symbols out of it.

  Runs every `:rebalance_interval_ms` (default 5 min) when enabled.
  Behavior is gated on `:counterflow, :auto_promote_enabled?` so the
  user can flip it off globally; pinned symbols are never demoted.
  """

  use GenServer
  require Logger

  alias Counterflow.{Repo, Watchlist, Watchlist.Manager, Watchlist.Promotion}
  alias Counterflow.Market.WatchlistEntry

  @default_interval_ms 5 * 60 * 1_000
  @default_target_size 30
  @demote_quiet_minutes 24 * 60
  @hysteresis_minutes 30

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @doc "Run a rebalance pass right now (synchronously)."
  def rebalance_now, do: GenServer.call(__MODULE__, :rebalance, 30_000)

  # ── server callbacks ────────────────────────────────────────

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? do
      interval = Keyword.get(opts, :rebalance_interval_ms, @default_interval_ms)
      Process.send_after(self(), :rebalance, interval)

      {:ok,
       %{
         interval: interval,
         target_size: Keyword.get(opts, :target_size, @default_target_size),
         last_demoted: %{}
       }}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:rebalance, state) do
    state = if globally_enabled?(), do: do_rebalance(state), else: state
    Process.send_after(self(), :rebalance, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:rebalance, _from, state) do
    {:reply, do_rebalance(state), state}
  end

  # ── work ────────────────────────────────────────────────────

  defp globally_enabled? do
    Application.get_env(:counterflow, :auto_promote_enabled?, true)
  end

  defp do_rebalance(state) do
    current = Watchlist.symbols() |> length()
    pinned = pinned_count()
    headroom = max(state.target_size - current, 0)

    candidates =
      Promotion.rank_candidates(limit: headroom * 2)
      |> Enum.reject(&under_hysteresis?(&1.symbol, state.last_demoted))

    promoted = Enum.take(candidates, headroom)

    Enum.each(promoted, fn cand ->
      Manager.add(cand.symbol)
      Watchlist.promote(cand.symbol, "auto:#{cand.reason}", cand.score)

      Logger.info(
        "Watchlist promoted #{cand.symbol} (score=#{cand.score}, reason=#{cand.reason})"
      )

      :telemetry.execute(
        [:counterflow, :watchlist, :promoted],
        %{score: cand.score},
        %{symbol: cand.symbol, reason: cand.reason}
      )
    end)

    # Demotion: if at-or-over target AND there are quiet non-pinned symbols
    over = max(current - state.target_size, 0)

    {demoted_now, last_demoted} =
      if over > 0 do
        quiet = Promotion.rank_quiet(quiet_window_minutes: @demote_quiet_minutes)
        to_drop = Enum.take(quiet, over)
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        Enum.each(to_drop, fn sym ->
          Manager.drop(sym)

          Logger.info("Watchlist demoted #{sym} (quiet for #{@demote_quiet_minutes}m)")

          :telemetry.execute(
            [:counterflow, :watchlist, :demoted],
            %{count: 1},
            %{symbol: sym}
          )
        end)

        new_last_demoted =
          Enum.reduce(to_drop, state.last_demoted, fn sym, acc ->
            Map.put(acc, sym, now)
          end)

        {to_drop, new_last_demoted}
      else
        {[], state.last_demoted}
      end

    last_demoted = prune_hysteresis(last_demoted)

    %{
      state
      | last_demoted: last_demoted
    }
    |> Map.put(:promoted, promoted)
    |> Map.put(:demoted, demoted_now)
    |> Map.put(:current_size, current)
    |> Map.put(:pinned, pinned)
  end

  defp pinned_count do
    import Ecto.Query
    Repo.aggregate(from(w in WatchlistEntry, where: w.pinned == true), :count)
  end

  defp under_hysteresis?(symbol, last_demoted) do
    case Map.get(last_demoted, symbol) do
      nil ->
        false

      ts ->
        DateTime.diff(DateTime.utc_now(), ts, :second) < @hysteresis_minutes * 60
    end
  end

  defp prune_hysteresis(last_demoted) do
    cutoff = DateTime.add(DateTime.utc_now(), -@hysteresis_minutes * 60, :second)
    Enum.filter(last_demoted, fn {_sym, ts} -> DateTime.compare(ts, cutoff) == :gt end) |> Map.new()
  end
end

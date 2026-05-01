defmodule Counterflow.Backtest.AutoTuner do
  @moduledoc """
  Nightly threshold sweeper. For every symbol with `auto_tune_enabled=true`
  in symbol_strategy_config, runs the backtester at multiple thresholds,
  picks the best by composite score (profit factor weighted by signal
  density), and writes the winner back into the symbol's config row plus
  an `auto_tune_runs` audit log entry.

  Selection criterion (configurable):
    score = profit_factor * (1 + log10(signals + 1)) when win_rate >= 0.45,
    else 0. Picks the threshold with the highest score; falls back to no
    change if no threshold cleared.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Counterflow.{Repo, Backtest.Runner, Strategy.Config}

  @default_grid [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]
  @default_lookback_days 7
  @default_interval "5m"

  # Schedule daily at 00:30 UTC; configurable via :counterflow, :auto_tune_at_utc
  @schedule_check_ms 5 * 60 * 1000

  # ── public API ──────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @doc """
  Run the tuner now (synchronously) for one or all enabled symbols.
  Returns a list of per-symbol summaries.
  """
  def run_now(symbol \\ :all), do: GenServer.call(__MODULE__, {:run_now, symbol}, :infinity)

  # ── server callbacks ────────────────────────────────────────

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? do
      schedule_check()
      {:ok, %{last_run_date: nil}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:check, state) do
    schedule_check()

    today = Date.utc_today()
    {h, m} = scheduled_time()
    now = DateTime.utc_now()

    cond do
      state.last_run_date == today ->
        {:noreply, state}

      now.hour > h or (now.hour == h and now.minute >= m) ->
        Task.start(fn -> do_run(:all) end)
        {:noreply, %{state | last_run_date: today}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:run_now, symbol}, _from, state) do
    {:reply, do_run(symbol), state}
  end

  defp schedule_check, do: Process.send_after(self(), :check, @schedule_check_ms)

  defp scheduled_time do
    Application.get_env(:counterflow, :auto_tune_at_utc, {0, 30})
  end

  # ── work ────────────────────────────────────────────────────

  defp do_run(:all) do
    enabled_symbols()
    |> Enum.map(&do_run_one/1)
  end

  defp do_run(symbol) when is_binary(symbol) do
    [do_run_one(symbol)]
  end

  defp enabled_symbols do
    Repo.all(from c in Config, where: c.auto_tune_enabled == true, select: c.symbol)
  end

  defp do_run_one(symbol) do
    cfg = Config.for(symbol)
    interval = cfg.interval || @default_interval
    grid = Application.get_env(:counterflow, :auto_tune_grid, @default_grid)
    days = Application.get_env(:counterflow, :auto_tune_lookback_days, @default_lookback_days)

    Logger.info("auto_tune sweep starting for #{symbol}/#{interval} across #{length(grid)} thresholds")

    to = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    from = DateTime.add(to, -days * 86_400, :second)

    evaluated =
      grid
      |> Enum.map(fn threshold ->
        result =
          Runner.run(
            symbol: symbol,
            interval: interval,
            from: from,
            to: to,
            strategy_opts: [threshold: threshold]
          )

        %{
          threshold: threshold,
          signals: result.summary.total,
          win_rate: result.summary.win_rate,
          profit_factor: result.summary.profit_factor,
          avg_r: result.summary.avg_r,
          sum_r: result.summary.sum_r,
          max_dd_r: result.summary.max_drawdown_r,
          score: composite_score(result.summary)
        }
      end)

    winner = Enum.max_by(evaluated, & &1.score, fn -> nil end)

    summary = %{
      ran_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      lookback_days: days,
      interval: interval,
      grid: evaluated,
      winner: winner,
      previous_threshold: cfg.threshold && Decimal.to_string(cfg.threshold |> to_decimal(), :normal)
    }

    apply_winner(symbol, cfg, winner, summary)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("auto_tune_runs", [
      %{
        symbol: symbol,
        interval: interval,
        ran_at: summary.ran_at,
        previous_threshold: maybe_decimal(cfg.threshold),
        selected_threshold: winner && Decimal.from_float(winner.threshold),
        evaluated: jsonable(%{grid: evaluated, winner: winner}),
        inserted_at: now,
        updated_at: now
      }
    ])

    Phoenix.PubSub.broadcast(Counterflow.PubSub, "auto_tune:done", {:auto_tune, symbol, summary})

    Logger.info(
      "auto_tune #{symbol}: winner threshold=#{winner && winner.threshold} score=#{winner && Float.round(winner.score, 3)}"
    )

    %{symbol: symbol, summary: summary}
  end

  defp composite_score(summary), do: Counterflow.Backtest.AutoTunerScoring.composite(summary)

  defp apply_winner(_symbol, _cfg, nil, _summary), do: :ok

  defp apply_winner(symbol, _cfg, winner, summary) do
    Config.upsert(symbol, %{
      threshold: Decimal.from_float(winner.threshold),
      last_auto_tune_at: summary.ran_at,
      last_auto_tune_summary: jsonable(summary)
    })
  end

  defp maybe_decimal(nil), do: nil
  defp maybe_decimal(%Decimal{} = d), do: d
  defp maybe_decimal(n) when is_number(n), do: Decimal.from_float(n / 1)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.from_float(n / 1)
  defp to_decimal(_), do: Decimal.new(0)

  # Recursively convert Decimal/Atom keys/Atoms to JSON-safe values so the
  # entire structure can be serialized into the JSONB columns.
  defp jsonable(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%Date{} = d), do: Date.to_iso8601(d)
  defp jsonable(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      k_out = if is_atom(k) and k not in [nil, true, false], do: Atom.to_string(k), else: k
      {k_out, jsonable(v)}
    end)
  end
  defp jsonable(other), do: other
end

defmodule Counterflow.Backtest.WalkForward do
  @moduledoc """
  Walk-forward validation. The single-window backtester (Runner) is prone
  to overfitting: pick the threshold that maximized PF over the last 7d,
  and you've trained on noise. Walk-forward splits the history into
  rolling train/test pairs:

      [train_w1] [test_w1]
                 [train_w2] [test_w2]
                            [train_w3] [test_w3]
                                       …

  Each window:
    1. on `train`, sweep the threshold grid and pick the winner by
       composite score (the same scorer the AutoTuner uses).
    2. on `test`, run the strategy with that frozen threshold.
    3. record both the in-sample winner and the out-of-sample result.

  An overfit strategy looks great on train and falls apart on test —
  this surfaces it immediately.
  """

  alias Counterflow.Backtest.{Runner, AutoTunerScoring}

  @default_grid [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]

  @type window :: %{
          train: %{from: DateTime.t(), to: DateTime.t()},
          test: %{from: DateTime.t(), to: DateTime.t()},
          train_winner: map() | nil,
          test_summary: map(),
          frozen_threshold: float() | nil
        }

  @type report :: %{
          symbol: String.t(),
          interval: String.t(),
          windows: [window()],
          aggregate: map()
        }

  @spec run(keyword()) :: report()
  def run(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    interval = Keyword.fetch!(opts, :interval)
    train_days = Keyword.get(opts, :train_days, 7)
    test_days = Keyword.get(opts, :test_days, 2)
    total_days = Keyword.get(opts, :total_days, 30)
    grid = Keyword.get(opts, :grid, @default_grid)

    end_time = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    start_time = DateTime.add(end_time, -total_days * 86_400, :second)

    windows = build_windows(start_time, end_time, train_days, test_days)

    completed =
      Enum.map(windows, fn {train_range, test_range} ->
        train_winner = optimize_on_train(symbol, interval, train_range, grid)
        frozen = train_winner && train_winner.threshold

        test_summary =
          if is_nil(frozen) do
            empty_summary()
          else
            test_run =
              Runner.run(
                symbol: symbol,
                interval: interval,
                from: test_range.from,
                to: test_range.to,
                strategy_opts: [threshold: frozen]
              )

            test_run.summary
          end

        %{
          train: train_range,
          test: test_range,
          train_winner: train_winner,
          test_summary: test_summary,
          frozen_threshold: frozen
        }
      end)

    %{
      symbol: symbol,
      interval: interval,
      windows: completed,
      aggregate: aggregate(completed)
    }
  end

  defp build_windows(start_dt, end_dt, train_days, test_days) do
    step_seconds = test_days * 86_400
    train_seconds = train_days * 86_400

    Stream.unfold(start_dt, fn cursor ->
      train_end = DateTime.add(cursor, train_seconds, :second)
      test_end = DateTime.add(train_end, step_seconds, :second)

      cond do
        DateTime.compare(test_end, end_dt) == :gt -> nil
        true ->
          {
            {%{from: cursor, to: train_end}, %{from: train_end, to: test_end}},
            DateTime.add(cursor, step_seconds, :second)
          }
      end
    end)
    |> Enum.to_list()
  end

  defp optimize_on_train(symbol, interval, range, grid) do
    grid
    |> Enum.map(fn threshold ->
      result =
        Runner.run(
          symbol: symbol,
          interval: interval,
          from: range.from,
          to: range.to,
          strategy_opts: [threshold: threshold]
        )

      %{
        threshold: threshold,
        signals: result.summary.total,
        win_rate: result.summary.win_rate,
        profit_factor: result.summary.profit_factor,
        sum_r: result.summary.sum_r,
        score: AutoTunerScoring.composite(result.summary)
      }
    end)
    |> Enum.max_by(& &1.score, fn -> nil end)
  end

  defp aggregate(windows) do
    test_results = Enum.map(windows, & &1.test_summary)
    n = length(test_results)
    total_signals = Enum.sum(Enum.map(test_results, &Map.get(&1, :total, 0)))
    sum_r = Enum.sum(Enum.map(test_results, &Map.get(&1, :sum_r, 0.0)))

    win_rates = Enum.map(test_results, &Map.get(&1, :win_rate, 0.0))
    pfs = Enum.map(test_results, &Map.get(&1, :profit_factor, 0.0))

    profitable_windows = Enum.count(test_results, &(Map.get(&1, :sum_r, 0.0) > 0))

    %{
      windows: n,
      profitable_windows: profitable_windows,
      consistency: if(n > 0, do: profitable_windows / n, else: 0.0),
      total_signals_oos: total_signals,
      total_sum_r_oos: sum_r,
      avg_win_rate_oos: if(n > 0, do: Enum.sum(win_rates) / n, else: 0.0),
      avg_pf_oos: if(n > 0, do: avg_pf(pfs), else: 0.0)
    }
  end

  defp avg_pf(pfs) do
    valid = Enum.filter(pfs, &(is_number(&1) and &1 > 0 and &1 < 1_000))
    if valid == [], do: 0.0, else: Enum.sum(valid) / length(valid)
  end

  defp empty_summary do
    %{
      total: 0,
      win_rate: 0.0,
      profit_factor: 0.0,
      avg_r: 0.0,
      sum_r: 0.0,
      max_drawdown_r: 0.0
    }
  end
end

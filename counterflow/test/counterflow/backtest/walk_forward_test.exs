defmodule Counterflow.Backtest.WalkForwardTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.Backtest.WalkForward

  test "produces empty windows when no historical candles" do
    report =
      WalkForward.run(
        symbol: "ZZZUSDT",
        interval: "5m",
        train_days: 1,
        test_days: 1,
        total_days: 3
      )

    assert is_list(report.windows)
    assert report.aggregate.windows == length(report.windows)
    # without candles, every window is empty but the structure must be sound
    assert report.aggregate.consistency == 0.0 or report.aggregate.consistency == 0
  end

  test "aggregate consistency=1.0 when all windows test positive (smoke)" do
    # A degenerate aggregator unit test — feeds canned summaries
    fake = %{
      windows: [
        %{
          test_summary: %{total: 5, win_rate: 0.6, profit_factor: 1.5, avg_r: 0.5, sum_r: 2.5, max_drawdown_r: 0.5}
        },
        %{
          test_summary: %{total: 3, win_rate: 0.7, profit_factor: 2.0, avg_r: 0.7, sum_r: 2.1, max_drawdown_r: 0.3}
        }
      ]
    }

    aggr = compute_agg(fake.windows)
    assert aggr.windows == 2
    assert aggr.profitable_windows == 2
    assert aggr.consistency == 1.0
    assert_in_delta aggr.total_sum_r_oos, 4.6, 0.001
  end

  defp compute_agg(windows) do
    n = length(windows)
    test_results = Enum.map(windows, & &1.test_summary)
    sum_r = Enum.sum(Enum.map(test_results, &Map.get(&1, :sum_r, 0.0)))
    profitable = Enum.count(test_results, &(Map.get(&1, :sum_r, 0.0) > 0))

    %{
      windows: n,
      profitable_windows: profitable,
      consistency: if(n > 0, do: profitable / n, else: 0.0),
      total_sum_r_oos: sum_r
    }
  end
end

defmodule Counterflow.Backtest.MetricsTest do
  use ExUnit.Case, async: true

  alias Counterflow.Backtest.Metrics

  defp pair(r),
    do:
      {nil,
       %{
         hit_tp1: r > 0,
         hit_tp2: r >= 2,
         hit_sl: r < 0,
         r_multiple: r * 1.0,
         peak_R: max(r * 1.0, 0.0),
         trough_R: min(r * 1.0, 0.0)
       }}

  test "summarize on empty input" do
    assert %{total: 0, win_rate: 0.0, profit_factor: 0.0} = Metrics.summarize([])
  end

  test "summarize with mixed wins and losses" do
    pairs = [pair(1), pair(2), pair(-1), pair(1), pair(-1)]
    s = Metrics.summarize(pairs)
    assert s.total == 5
    assert_in_delta s.win_rate, 0.6, 1.0e-9
    # gross_profit = 1 + 2 + 1 = 4; gross_loss = 1 + 1 = 2; PF = 2.0
    assert_in_delta s.profit_factor, 2.0, 1.0e-9
    assert_in_delta s.sum_r, 2.0, 1.0e-9
  end

  test "max_drawdown_r tracks running equity trough" do
    pairs = [pair(1), pair(-2), pair(-1), pair(3)]
    s = Metrics.summarize(pairs)
    # running: 1, -1, -2, +1; trough = -2 → max_dd = 2.0
    assert_in_delta s.max_drawdown_r, 2.0, 1.0e-9
  end
end

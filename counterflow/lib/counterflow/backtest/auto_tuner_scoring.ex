defmodule Counterflow.Backtest.AutoTunerScoring do
  @moduledoc """
  Composite score used to rank backtest results across thresholds.
  Extracted so AutoTuner and WalkForward can share it.

  score = profit_factor × (1 + log10(signals + 1))   when win_rate >= 0.45
        = 0                                          otherwise
  """

  @spec composite(map()) :: float()
  def composite(%{total: 0}), do: 0.0

  def composite(s) do
    if is_number(s.win_rate) and s.win_rate < 0.45 do
      0.0
    else
      pf = if is_number(s.profit_factor), do: min(s.profit_factor, 10.0), else: 0.0
      pf * (1 + :math.log10(s.total + 1))
    end
  end
end

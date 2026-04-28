defmodule Counterflow.Clock do
  @moduledoc """
  Pluggable clock so the same strategy code can run live or in replay mode.

  In live mode (default) `now/0` returns `DateTime.utc_now/0`. In replay mode
  the engine sets `Process.put(:replay_clock, ts)` before each event and
  `now/0` returns that.
  """

  def now do
    case Process.get(:replay_clock) do
      nil -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
      %DateTime{} = dt -> dt
    end
  end

  def set_replay_now(%DateTime{} = dt), do: Process.put(:replay_clock, dt)
  def clear_replay, do: Process.delete(:replay_clock)
end

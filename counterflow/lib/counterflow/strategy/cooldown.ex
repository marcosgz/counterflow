defmodule Counterflow.Strategy.Cooldown do
  @moduledoc """
  Per-(symbol, side) ETS-backed cool-down. Prevents the same direction from
  emitting twice within `cooldown_minutes`.
  """

  use GenServer

  @table :counterflow_cooldown

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Returns `:ok` if the (symbol, side) pair is allowed to emit; `:cooldown` if
  still cooling down. On `:ok`, also stamps the latest emit time.
  """
  def maybe_emit(symbol, side, interval) do
    cooldown_minutes = cooldown_for(interval)
    key = {symbol, side}
    now = System.system_time(:second)
    minimum_age = cooldown_minutes * 60

    case :ets.lookup(@table, key) do
      [{^key, last}] when now - last < minimum_age -> :cooldown
      _ ->
        :ets.insert(@table, {key, now})
        :ok
    end
  end

  @doc "Reset state — for tests."
  def reset, do: :ets.delete_all_objects(@table)

  defp cooldown_for("1m"), do: 5
  defp cooldown_for("5m"), do: 15
  defp cooldown_for("15m"), do: 30
  defp cooldown_for("1h"), do: 60
  defp cooldown_for("4h"), do: 240
  defp cooldown_for(_), do: 15
end

defmodule Counterflow.Reports.Scheduler do
  @moduledoc """
  Weekly digest scheduler. Wakes every 5 min, fires the digest once per
  week past the configured weekday + UTC time. Default: Sundays at
  23:00 UTC. Override via `:counterflow, :digest_at` => {weekday, hour, minute}
  where weekday is 1 (Mon) .. 7 (Sun).
  """

  use GenServer
  require Logger

  alias Counterflow.Reports.WeeklyDigest

  @check_ms 5 * 60 * 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? do
      Process.send_after(self(), :check, @check_ms)
      {:ok, %{last_run_date: nil}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_ms)

    {target_weekday, target_hour, target_minute} = scheduled_time()
    today = Date.utc_today()
    now = DateTime.utc_now()
    current_weekday = Date.day_of_week(today)

    cond do
      state.last_run_date == today ->
        {:noreply, state}

      current_weekday != target_weekday ->
        {:noreply, state}

      now.hour > target_hour or
          (now.hour == target_hour and now.minute >= target_minute) ->
        Task.start(fn -> safe_send() end)
        {:noreply, %{state | last_run_date: today}}

      true ->
        {:noreply, state}
    end
  end

  defp scheduled_time do
    Application.get_env(:counterflow, :digest_at, {7, 23, 0})
  end

  defp safe_send do
    case WeeklyDigest.send_now() do
      {:ok, _} -> Logger.info("WeeklyDigest sent")
      {:error, reason} -> Logger.warning("WeeklyDigest failed: #{inspect(reason)}")
    end
  end
end

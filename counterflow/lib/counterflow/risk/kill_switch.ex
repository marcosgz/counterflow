defmodule Counterflow.Risk.KillSwitch do
  @moduledoc """
  Process- and env-level emergency stop. Live order placement consults this
  on every attempt; engaging it (via `engage/2`) blocks all new orders until
  explicitly released.

  The state is also seeded from the env var `COUNTERFLOW_KILL=1` at boot so
  operators can engage it without needing IEx access.
  """

  use GenServer
  require Logger

  alias Counterflow.Repo
  alias Counterflow.Risk.KillswitchEvent

  @table :counterflow_killswitch

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    if System.get_env("COUNTERFLOW_KILL") == "1" do
      :ets.insert(@table, {:state, true})
      Logger.warning("KillSwitch engaged at boot via COUNTERFLOW_KILL env var")
    else
      :ets.insert(@table, {:state, false})
    end

    {:ok, %{}}
  end

  def engaged?, do: ([{:state, v}] = :ets.lookup(@table, :state)) && v
  def disengaged?, do: !engaged?()

  def engage(reason, by \\ "system") do
    :ets.insert(@table, {:state, true})

    persist_event(%{
      engaged_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      engaged_by: by,
      reason: reason
    })

    Logger.warning("KillSwitch engaged by #{by}: #{reason}")
    :ok
  end

  def release(by \\ "system") do
    :ets.insert(@table, {:state, false})
    update_latest_release(by)
    Logger.info("KillSwitch released by #{by}")
    :ok
  end

  defp persist_event(attrs) do
    %KillswitchEvent{}
    |> KillswitchEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp update_latest_release(by) do
    import Ecto.Query

    case Repo.one(
           from e in KillswitchEvent,
             where: is_nil(e.released_at),
             order_by: [desc: e.engaged_at],
             limit: 1
         ) do
      nil ->
        :ok

      %KillswitchEvent{} = e ->
        e
        |> KillswitchEvent.changeset(%{
          released_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          released_by: by
        })
        |> Repo.update!()

        :ok
    end
  end
end

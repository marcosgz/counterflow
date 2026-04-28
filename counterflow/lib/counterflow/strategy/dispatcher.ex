defmodule Counterflow.Strategy.Dispatcher do
  @moduledoc """
  Fan-out for emitted signals. Persists the signal, broadcasts on PubSub,
  forwards to configured alert sinks. Each sink runs in a Task so a slow
  Telegram POST never blocks the strategy loop.
  """

  require Logger

  alias Counterflow.{Repo, Strategy.Signal}
  alias Phoenix.PubSub

  def dispatch(%Signal{} = sig) do
    case persist(sig) do
      :ok ->
        PubSub.broadcast(Counterflow.PubSub, "signals:new", {:signal, sig})
        PubSub.broadcast(Counterflow.PubSub, "signals:#{sig.symbol}", {:signal, sig})
        run_sinks(sig)
        {:ok, sig}

      {:error, reason} ->
        Logger.warning("dispatcher persist failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp persist(sig) do
    attrs = sig |> Map.from_struct() |> Map.delete(:__meta__)

    %Signal{}
    |> Signal.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:id, :generated_at])
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  defp run_sinks(sig) do
    sinks = active_sinks()

    Enum.each(sinks, fn sink ->
      Task.start(fn ->
        try do
          sink.send(sig)
        rescue
          err -> Logger.warning("sink #{inspect(sink)} failed: #{Exception.message(err)}")
        end
      end)
    end)
  end

  # Sinks come from explicit config OR are auto-enabled when credentials exist.
  defp active_sinks do
    explicit = Application.get_env(:counterflow, :alert_sinks, [])
    auto = if Counterflow.Alerts.Telegram.configured?(), do: [Counterflow.Alerts.Telegram], else: []
    Enum.uniq(explicit ++ auto)
  end
end

defmodule Counterflow.Strategy.OutcomeEvaluator do
  @moduledoc """
  Resolves the outcome of every emitted signal.

  Subscribes to `signals:new`. For each signal, schedules itself to run
  after `ttl_minutes` have passed; at that time it walks the candles
  between `generated_at` and `generated_at + ttl_minutes`, determines which
  bracket (TP1 / TP2 / SL) was hit first, and writes the result back into
  `signals.outcome` JSONB.

  Reuses `Counterflow.Backtest.Metrics.evaluate_outcome/2` so backtests and
  live evaluation share one source of truth.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Counterflow.{Repo, Backtest.Metrics, Market.Candle, Strategy.Signal}
  alias Phoenix.PubSub

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    if enabled? do
      PubSub.subscribe(Counterflow.PubSub, "signals:new")
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:signal, %Signal{} = sig}, state) do
    delay_ms = max(sig.ttl_minutes * 60 * 1000, 60_000)
    Process.send_after(self(), {:resolve, sig.id, sig.generated_at}, delay_ms)
    {:noreply, state}
  end

  def handle_info({:resolve, sig_id, generated_at}, state) do
    Task.start(fn -> resolve(sig_id, generated_at) end)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp resolve(sig_id, generated_at) do
    case Repo.one(
           from s in Signal,
             where: s.id == ^sig_id and s.generated_at == ^generated_at,
             limit: 1
         ) do
      nil ->
        :ok

      %Signal{outcome: outcome} = sig when is_map(outcome) and map_size(outcome) > 0 ->
        Logger.debug("outcome already recorded for #{sig.id}")
        :ok

      %Signal{} = sig ->
        future = load_future_candles(sig)
        outcome = Metrics.evaluate_outcome(sig, future)
        update_outcome(sig, outcome)

        :telemetry.execute(
          [:counterflow, :strategy, :outcome, :resolved],
          %{count: 1, r_multiple: outcome.r_multiple},
          %{symbol: sig.symbol, side: sig.side}
        )
    end
  rescue
    err ->
      Logger.warning("outcome eval failed for #{sig_id}: #{Exception.message(err)}")
  end

  defp load_future_candles(%Signal{symbol: sym, interval: int, generated_at: ts, ttl_minutes: ttl}) do
    until = DateTime.add(ts, ttl * 60, :second)

    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^sym and c.interval == ^int and c.closed == true and
            c.time >= ^ts and c.time <= ^until,
        order_by: [asc: c.time]
    )
  end

  defp update_outcome(sig, outcome) do
    Repo.update_all(
      from(s in Signal, where: s.id == ^sig.id and s.generated_at == ^sig.generated_at),
      set: [outcome: outcome]
    )
  end
end

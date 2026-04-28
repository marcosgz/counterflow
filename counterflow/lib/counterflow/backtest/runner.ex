defmodule Counterflow.Backtest.Runner do
  @moduledoc """
  Run a backtest end-to-end: replay historical candles through the
  strategy, walk forward to evaluate each emitted signal's outcome,
  and summarize win-rate / profit-factor / R-multiples.

  Reuses Counterflow.Backtest.Replayer (signal generation) + Metrics
  (outcome resolution) so backtests share the live code path verbatim.
  """

  import Ecto.Query

  alias Counterflow.Repo
  alias Counterflow.Backtest.{Replayer, Metrics}
  alias Counterflow.Market.Candle

  @type result :: %{
          signals: [{Counterflow.Strategy.Signal.t(), Metrics.outcome()}],
          summary: map(),
          replay: map()
        }

  @doc """
  Runs the backtest and resolves every signal's outcome against future
  candles available in the DB. `:opts` are forwarded to `Replayer.run/1`.
  """
  @spec run(keyword()) :: result()
  def run(opts) do
    replay = Replayer.run(opts)

    pairs =
      Enum.map(replay.signals, fn sig ->
        future = future_candles(sig)
        {sig, Metrics.evaluate_outcome(sig, future)}
      end)

    %{
      signals: pairs,
      summary: Metrics.summarize(pairs),
      replay: %{
        candles_processed: replay.candles_processed,
        duration_ms: replay.duration_ms
      }
    }
  end

  defp future_candles(sig) do
    until = DateTime.add(sig.generated_at, sig.ttl_minutes * 60, :second)

    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^sig.symbol and c.interval == ^sig.interval and c.closed == true and
            c.time >= ^sig.generated_at and c.time <= ^until,
        order_by: [asc: c.time]
    )
  end
end

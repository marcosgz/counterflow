defmodule Counterflow.Ingest.Backfill do
  @moduledoc """
  Historical kline backfill for newly-promoted symbols. When a symbol is
  added to the watchlist (manually or auto-promoted), it has no candle
  history — the strategy can't evaluate until candles accumulate. This
  module pages the Binance REST `/fapi/v1/klines` endpoint backwards in
  500-row chunks and upserts into the `candles` hypertable so the
  strategy is useful from the first tick.

  Runs in a Task supervisor so multiple backfills can proceed in
  parallel without blocking the caller.
  """

  require Logger
  alias Counterflow.{Repo, Binance.Rest, Market.Candle}

  @default_intervals ["1m", "5m"]
  @default_days 7
  @page_limit 500

  @doc """
  Kick off backfill for a symbol across the given intervals (default
  ["1m","5m"]) over the last N days. Returns `:ok` immediately; the
  actual work runs async per (symbol, interval) pair.
  """
  @spec start_async(String.t(), keyword()) :: :ok
  def start_async(symbol, opts \\ []) do
    intervals = Keyword.get(opts, :intervals, @default_intervals)
    days = Keyword.get(opts, :days, @default_days)

    Enum.each(intervals, fn interval ->
      Task.start(fn ->
        try do
          run(symbol, interval, days)
        rescue
          err ->
            Logger.warning("backfill failed for #{symbol}/#{interval}: #{Exception.message(err)}")
        end
      end)
    end)

    :ok
  end

  @doc "Synchronous backfill — returns count of candles persisted."
  @spec run(String.t(), String.t(), pos_integer()) :: non_neg_integer()
  def run(symbol, interval, days) do
    end_ms = System.system_time(:millisecond)
    start_ms = end_ms - days * 86_400_000

    Logger.info("backfill #{symbol}/#{interval}: #{days}d, paging from now backward")

    page(symbol, interval, end_ms, start_ms, 0)
  end

  defp page(_sym, _int, end_ms, start_ms, total) when end_ms <= start_ms, do: total

  defp page(symbol, interval, end_ms, start_ms, total) do
    case Rest.klines(symbol, interval, endTime: end_ms, limit: @page_limit) do
      {:ok, []} ->
        total

      {:ok, rows} when is_list(rows) ->
        records = Enum.map(rows, &row_to_record(&1, symbol, interval))
        persist(records)
        oldest_ms = rows |> List.first() |> List.first()
        # avoid infinite loop on the same window
        next_end = oldest_ms - 1
        if next_end <= start_ms or length(rows) < @page_limit do
          total + length(rows)
        else
          # Polite throttle: 100ms between pages keeps us well under rate limits.
          Process.sleep(100)
          page(symbol, interval, next_end, start_ms, total + length(rows))
        end

      {:error, err} ->
        Logger.warning("backfill kline error for #{symbol}/#{interval}: #{Exception.message(err)}")
        total
    end
  end

  defp row_to_record([t, o, h, l, c, v, _ct, qv, n, tbb, tbq, _ignore], symbol, interval) do
    %{
      symbol: symbol,
      interval: interval,
      time: DateTime.from_unix!(t * 1000, :microsecond),
      open: dec(o),
      high: dec(h),
      low: dec(l),
      close: dec(c),
      volume: dec(v),
      quote_volume: dec(qv),
      trades: n,
      taker_buy_base: dec(tbb),
      taker_buy_quote: dec(tbq),
      closed: true
    }
  end

  defp persist([]), do: :ok

  defp persist(records) do
    Repo.insert_all(Candle, records,
      on_conflict: {:replace_all_except, [:symbol, :interval, :time]},
      conflict_target: [:symbol, :interval, :time]
    )

    :ok
  end

  defp dec(nil), do: nil
  defp dec(s) when is_binary(s), do: Decimal.new(s)
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(f) when is_float(f), do: Decimal.from_float(f)
end

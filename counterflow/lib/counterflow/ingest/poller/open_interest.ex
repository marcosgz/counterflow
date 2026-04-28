defmodule Counterflow.Ingest.Poller.OpenInterest do
  @moduledoc "Periodic poller for /futures/data/openInterestHist for each watchlist symbol."

  use Counterflow.Ingest.Poller, name: :open_interest, interval_ms: 5 * 60 * 1000

  alias Counterflow.{Binance.Rest, Repo, Market.OpenInterest, Watchlist}

  def poll(_state) do
    Watchlist.symbols()
    |> Enum.each(fn symbol ->
      with {:ok, rows} <- Rest.open_interest_hist(symbol, period: "5m", limit: 30) do
        records = Enum.map(rows, &row_to_record(&1, symbol))
        upsert(records)
      end

      Process.sleep(50)
    end)
  end

  defp row_to_record(
         %{"sumOpenInterest" => oi, "sumOpenInterestValue" => oiv, "timestamp" => ts},
         symbol
       ) do
    %{
      symbol: symbol,
      time: ms_to_dt(ts),
      open_interest: dec(oi),
      oi_value: dec(oiv)
    }
  end

  defp upsert([]), do: :ok

  defp upsert(records) do
    Repo.insert_all(OpenInterest, records,
      on_conflict: {:replace_all_except, [:symbol, :time]},
      conflict_target: [:symbol, :time]
    )

    :ok
  end

  defp ms_to_dt(ms) when is_integer(ms), do: DateTime.from_unix!(ms * 1000, :microsecond)
  defp dec(nil), do: nil
  defp dec(s) when is_binary(s), do: Decimal.new(s)
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(f) when is_float(f), do: Decimal.from_float(f)
end

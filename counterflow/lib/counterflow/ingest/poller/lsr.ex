defmodule Counterflow.Ingest.Poller.LSR do
  @moduledoc "Periodic poller for global account L/S and top-trader-position L/S."

  use Counterflow.Ingest.Poller, name: :lsr, interval_ms: 5 * 60 * 1000

  alias Counterflow.{Binance.Rest, Repo, Market.LongShortRatio, Watchlist}

  @sources [
    {:global_account, &Rest.long_short_account_ratio/2},
    {:top_position, &Rest.top_long_short_position_ratio/2}
  ]

  def poll(_state) do
    symbols = Watchlist.symbols()

    Enum.each(@sources, fn {tag, fun} ->
      Enum.each(symbols, fn symbol ->
        case fun.(symbol, period: "5m", limit: 30) do
          {:ok, rows} -> upsert(rows, symbol, Atom.to_string(tag))
          _ -> :skip
        end

        Process.sleep(50)
      end)
    end)
  end

  defp upsert([], _symbol, _source), do: :ok

  defp upsert(rows, symbol, source) do
    records =
      Enum.map(rows, fn r ->
        %{
          symbol: symbol,
          source: source,
          time: ms_to_dt(r["timestamp"]),
          long_ratio: dec(r["longAccount"] || r["longPosition"]),
          short_ratio: dec(r["shortAccount"] || r["shortPosition"]),
          ls_ratio: dec(r["longShortRatio"])
        }
      end)

    Repo.insert_all(LongShortRatio, records,
      on_conflict: {:replace_all_except, [:symbol, :source, :time]},
      conflict_target: [:symbol, :source, :time]
    )

    :ok
  end

  defp ms_to_dt(ms) when is_integer(ms), do: DateTime.from_unix!(ms * 1000, :microsecond)
  defp dec(nil), do: nil
  defp dec(s) when is_binary(s), do: Decimal.new(s)
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(f) when is_float(f), do: Decimal.from_float(f)
end

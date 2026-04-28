defmodule Counterflow.Ingest.Poller.Funding do
  @moduledoc "Polls /fapi/v1/premiumIndex for ALL symbols once per cycle (single REST call)."

  use Counterflow.Ingest.Poller, name: :funding, interval_ms: 30 * 1000

  alias Counterflow.{Binance.Rest, Repo, Market.FundingRate}
  alias Phoenix.PubSub

  def poll(_state) do
    case Rest.premium_index() do
      {:ok, rows} when is_list(rows) ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        records =
          rows
          |> Enum.filter(&match?(%{"symbol" => _, "lastFundingRate" => _}, &1))
          |> Enum.map(fn r ->
            %{
              symbol: r["symbol"],
              time: now,
              funding_rate: dec(r["lastFundingRate"]),
              mark_price: dec(r["markPrice"]),
              index_price: dec(r["indexPrice"])
            }
          end)

        upsert(records)

        Enum.each(
          records,
          &PubSub.broadcast(Counterflow.PubSub, "mark_price:#{&1.symbol}", {:mark_price, &1})
        )

      _ ->
        :skip
    end
  end

  defp upsert([]), do: :ok

  defp upsert(records) do
    Repo.insert_all(FundingRate, records,
      on_conflict: {:replace_all_except, [:symbol, :time]},
      conflict_target: [:symbol, :time]
    )

    :ok
  end

  defp dec(nil), do: nil
  defp dec(s) when is_binary(s), do: Decimal.new(s)
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(f) when is_float(f), do: Decimal.from_float(f)
end

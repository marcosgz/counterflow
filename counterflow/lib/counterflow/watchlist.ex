defmodule Counterflow.Watchlist do
  @moduledoc """
  Read/write API for the watchlist plus dynamic supervision.

  Public functions are deliberately small; the per-symbol ingestion lifecycle
  is delegated to `Counterflow.Watchlist.Manager`.
  """

  import Ecto.Query

  alias Counterflow.{Repo, Market.WatchlistEntry, Watchlist.Manager}

  def symbols do
    case Process.whereis(Manager) do
      nil ->
        Repo.all(from w in WatchlistEntry, select: w.symbol)

      _ ->
        # cached snapshot
        Manager.symbols()
    end
  end

  def all, do: Repo.all(from w in WatchlistEntry, order_by: [desc: w.pinned, asc: w.symbol])

  def pin(symbol), do: upsert(symbol, %{pinned: true, promoted_by: "manual"})
  def unpin(symbol), do: upsert(symbol, %{pinned: false})

  def promote(symbol, by, score \\ nil) do
    upsert(symbol, %{
      promoted_by: to_string(by),
      promoted_score: score && Decimal.from_float(score),
      last_active_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end

  def remove(symbol) do
    Repo.delete_all(from w in WatchlistEntry, where: w.symbol == ^symbol)
    :ok
  end

  defp upsert(symbol, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      attrs
      |> Map.put_new(:added_at, now)
      |> Map.put_new(:last_active_at, now)
      |> Map.put(:symbol, symbol)

    %WatchlistEntry{}
    |> WatchlistEntry.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, Map.keys(attrs) -- [:symbol, :added_at]},
      conflict_target: [:symbol]
    )
  end
end

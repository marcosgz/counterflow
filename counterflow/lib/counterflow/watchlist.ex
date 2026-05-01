defmodule Counterflow.Watchlist do
  @moduledoc """
  Read/write API for the watchlist plus dynamic supervision.

  Every function takes an optional `user_id`; when omitted it falls back
  to `Counterflow.Accounts.owner_id/0`, so existing single-tenant call
  sites continue to work without explicit threading.
  """

  import Ecto.Query

  alias Counterflow.{Repo, Accounts, Market.WatchlistEntry, Watchlist.Manager}

  def symbols(user_id \\ nil) do
    uid = user_id || Accounts.owner_id()

    case Process.whereis(Manager) do
      nil ->
        if uid do
          Repo.all(from w in WatchlistEntry, where: w.user_id == ^uid, select: w.symbol)
        else
          []
        end

      _ ->
        Manager.symbols()
    end
  end

  def all(user_id \\ nil) do
    uid = user_id || Accounts.owner_id()

    if uid do
      Repo.all(
        from w in WatchlistEntry,
          where: w.user_id == ^uid,
          order_by: [desc: w.pinned, asc: w.symbol]
      )
    else
      []
    end
  end

  def pin(symbol, user_id \\ nil),
    do: upsert(symbol, user_id, %{pinned: true, promoted_by: "manual"})

  def unpin(symbol, user_id \\ nil), do: upsert(symbol, user_id, %{pinned: false})

  def promote(symbol, by, score \\ nil, user_id \\ nil) do
    upsert(symbol, user_id, %{
      promoted_by: to_string(by),
      promoted_score: score && Decimal.from_float(score),
      last_active_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end

  def remove(symbol, user_id \\ nil) do
    uid = user_id || Accounts.owner_id()
    if uid do
      Repo.delete_all(from w in WatchlistEntry, where: w.user_id == ^uid and w.symbol == ^symbol)
    end

    :ok
  end

  defp upsert(symbol, user_id, attrs) do
    uid = user_id || Accounts.owner_id() || raise "no owner user; create one first"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      attrs
      |> Map.put_new(:added_at, now)
      |> Map.put_new(:last_active_at, now)
      |> Map.put(:symbol, symbol)
      |> Map.put(:user_id, uid)

    %WatchlistEntry{}
    |> WatchlistEntry.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, Map.keys(attrs) -- [:symbol, :user_id, :added_at]},
      conflict_target: [:user_id, :symbol]
    )
  end
end

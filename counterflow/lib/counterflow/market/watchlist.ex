defmodule Counterflow.Market.WatchlistEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:symbol, :string, autogenerate: false}
  schema "watchlist" do
    field :added_at, :utc_datetime_usec
    field :pinned, :boolean, default: false
    field :promoted_by, :string
    field :promoted_score, :decimal
    field :last_active_at, :utc_datetime_usec
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:symbol, :added_at, :pinned, :promoted_by, :promoted_score, :last_active_at])
    |> validate_required([:symbol])
  end
end

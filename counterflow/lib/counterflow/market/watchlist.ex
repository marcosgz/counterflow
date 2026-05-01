defmodule Counterflow.Market.WatchlistEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "watchlist" do
    field :user_id, :integer, primary_key: true
    field :symbol, :string, primary_key: true
    field :added_at, :utc_datetime_usec
    field :pinned, :boolean, default: false
    field :promoted_by, :string
    field :promoted_score, :decimal
    field :last_active_at, :utc_datetime_usec
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :user_id,
      :symbol,
      :added_at,
      :pinned,
      :promoted_by,
      :promoted_score,
      :last_active_at
    ])
    |> validate_required([:user_id, :symbol])
  end
end

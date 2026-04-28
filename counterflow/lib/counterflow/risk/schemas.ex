defmodule Counterflow.Risk.KillswitchEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "killswitch_events" do
    field :engaged_at, :utc_datetime_usec
    field :engaged_by, :string
    field :reason, :string
    field :released_at, :utc_datetime_usec
    field :released_by, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(e, attrs) do
    e
    |> cast(attrs, [:engaged_at, :engaged_by, :reason, :released_at, :released_by])
    |> validate_required([:engaged_at, :engaged_by, :reason])
  end
end

defmodule Counterflow.Risk.Rejection do
  use Ecto.Schema
  import Ecto.Changeset

  schema "risk_rejections" do
    field :attempted_at, :utc_datetime_usec
    field :signal_id, :string
    field :symbol, :string
    field :side, :string
    field :rejected_by, :string
    field :details, :map
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(r, attrs) do
    r
    |> cast(attrs, [:attempted_at, :signal_id, :symbol, :side, :rejected_by, :details])
    |> validate_required([:attempted_at, :rejected_by])
  end
end

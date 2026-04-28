defmodule Counterflow.Strategy.Signal do
  @moduledoc """
  Single trade-signal struct, persisted to the `signals` hypertable and
  broadcast on PubSub topic `signals:new`.

  `components` is a map of indicator → signed contribution in [-1.0, 1.0]
  toward the chosen `side`; the linear weighted sum is the `score`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "signals" do
    field :id, :string, primary_key: true
    field :symbol, :string
    field :interval, :string
    field :side, :string
    field :score, :decimal
    field :components, :map
    field :price, :decimal
    field :leverage, :integer
    field :sl, :decimal
    field :tp1, :decimal
    field :tp2, :decimal
    field :ttl_minutes, :integer
    field :notes, {:array, :string}, default: []
    field :generated_at, :utc_datetime_usec, primary_key: true
    field :outcome, :map
  end

  @required ~w(id symbol interval side score components price leverage ttl_minutes generated_at)a
  @optional ~w(sl tp1 tp2 notes outcome)a

  def changeset(signal, attrs) do
    signal
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:side, ["long", "short"])
  end

  def build_id(symbol, interval, side, %DateTime{} = ts) do
    "#{symbol}:#{interval}:#{side}:#{DateTime.to_unix(ts)}"
  end
end

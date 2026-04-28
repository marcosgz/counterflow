defmodule Counterflow.Broker.PaperAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "paper_accounts" do
    field :initial_balance, :decimal
    field :balance, :decimal
    field :config, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(acc, attrs) do
    acc
    |> cast(attrs, [:id, :initial_balance, :balance, :config])
    |> validate_required([:id, :initial_balance, :balance])
  end
end

defmodule Counterflow.Broker.PaperOrder do
  use Ecto.Schema
  import Ecto.Changeset

  schema "paper_orders" do
    field :account_id, :string
    field :client_id, :string
    field :symbol, :string
    field :side, :string
    field :type, :string
    field :qty, :decimal
    field :price, :decimal
    field :stop_price, :decimal
    field :reduce_only, :boolean, default: false
    field :status, :string, default: "NEW"
    field :signal_id, :string
    field :intent, :string
    field :placed_at, :utc_datetime_usec
    field :filled_at, :utc_datetime_usec
    field :filled_qty, :decimal, default: Decimal.new(0)
    field :filled_avg, :decimal
    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(account_id client_id symbol side type qty status placed_at)a
  @optional ~w(price stop_price reduce_only signal_id intent filled_at filled_qty filled_avg)a

  def changeset(o, attrs) do
    o
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end

defmodule Counterflow.Broker.PaperFill do
  use Ecto.Schema
  import Ecto.Changeset

  schema "paper_fills" do
    field :order_id, :id
    field :account_id, :string
    field :symbol, :string
    field :side, :string
    field :price, :decimal
    field :qty, :decimal
    field :fee, :decimal, default: Decimal.new(0)
    field :realized_pnl, :decimal
    field :filled_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(f, attrs) do
    f
    |> cast(attrs, [:order_id, :account_id, :symbol, :side, :price, :qty, :fee, :realized_pnl, :filled_at])
    |> validate_required([:order_id, :account_id, :symbol, :side, :price, :qty, :filled_at])
  end
end

defmodule Counterflow.Broker.PaperPosition do
  use Ecto.Schema
  import Ecto.Changeset

  schema "paper_positions" do
    field :account_id, :string
    field :symbol, :string
    field :side, :string
    field :qty, :decimal
    field :entry_avg, :decimal
    field :leverage, :integer
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :realized_pnl, :decimal, default: Decimal.new(0)
    field :funding_paid, :decimal, default: Decimal.new(0)
    field :signal_id, :string
    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(account_id symbol side qty entry_avg leverage opened_at)a
  @optional ~w(closed_at realized_pnl funding_paid signal_id)a

  def changeset(p, attrs) do
    p
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end

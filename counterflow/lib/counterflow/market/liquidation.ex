defmodule Counterflow.Market.Liquidation do
  use Ecto.Schema

  @primary_key false
  schema "liquidations" do
    field :symbol, :string
    field :time, :utc_datetime_usec
    field :side, :string
    field :price, :decimal
    field :qty, :decimal
    field :order_type, :string
    field :status, :string
  end
end

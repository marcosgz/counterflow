defmodule Counterflow.Market.OpenInterest do
  use Ecto.Schema

  @primary_key false
  schema "open_interest" do
    field :symbol, :string, primary_key: true
    field :time, :utc_datetime_usec, primary_key: true
    field :open_interest, :decimal
    field :oi_value, :decimal
  end
end

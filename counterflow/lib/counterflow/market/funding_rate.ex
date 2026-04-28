defmodule Counterflow.Market.FundingRate do
  use Ecto.Schema

  @primary_key false
  schema "funding_rates" do
    field :symbol, :string, primary_key: true
    field :time, :utc_datetime_usec, primary_key: true
    field :funding_rate, :decimal
    field :mark_price, :decimal
    field :index_price, :decimal
  end
end

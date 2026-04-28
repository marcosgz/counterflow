defmodule Counterflow.Market.LongShortRatio do
  use Ecto.Schema

  @primary_key false
  schema "long_short_ratio" do
    field :symbol, :string, primary_key: true
    field :source, :string, primary_key: true
    field :time, :utc_datetime_usec, primary_key: true
    field :long_ratio, :decimal
    field :short_ratio, :decimal
    field :ls_ratio, :decimal
  end
end

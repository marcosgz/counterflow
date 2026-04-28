defmodule Counterflow.Market.Candle do
  use Ecto.Schema

  @primary_key false
  schema "candles" do
    field :symbol, :string, primary_key: true
    field :interval, :string, primary_key: true
    field :time, :utc_datetime_usec, primary_key: true
    field :open, :decimal
    field :high, :decimal
    field :low, :decimal
    field :close, :decimal
    field :volume, :decimal
    field :quote_volume, :decimal
    field :trades, :integer
    field :taker_buy_base, :decimal
    field :taker_buy_quote, :decimal
    field :closed, :boolean, default: false
  end

  @type t :: %__MODULE__{}
end

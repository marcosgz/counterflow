defmodule Counterflow.Repo.Migrations.CreateCandles do
  use Ecto.Migration

  def up do
    create table(:candles, primary_key: false) do
      add :symbol, :string, null: false, size: 32
      add :interval, :string, null: false, size: 8
      add :time, :utc_datetime_usec, null: false
      add :open, :decimal, precision: 24, scale: 12, null: false
      add :high, :decimal, precision: 24, scale: 12, null: false
      add :low, :decimal, precision: 24, scale: 12, null: false
      add :close, :decimal, precision: 24, scale: 12, null: false
      add :volume, :decimal, precision: 28, scale: 8, null: false
      add :quote_volume, :decimal, precision: 28, scale: 8
      add :trades, :integer, null: false
      add :taker_buy_base, :decimal, precision: 28, scale: 8
      add :taker_buy_quote, :decimal, precision: 28, scale: 8
      add :closed, :boolean, null: false, default: false
    end

    create unique_index(:candles, [:symbol, :interval, :time])

    execute(
      "SELECT create_hypertable('candles', 'time', chunk_time_interval => INTERVAL '7 days')"
    )
  end

  def down do
    drop table(:candles)
  end
end

defmodule Counterflow.Repo.Migrations.Phase2MarketData do
  use Ecto.Migration

  def up do
    # Open Interest hypertable
    create table(:open_interest, primary_key: false) do
      add :symbol, :string, null: false, size: 32
      add :time, :utc_datetime_usec, null: false
      add :open_interest, :decimal, precision: 28, scale: 8, null: false
      add :oi_value, :decimal, precision: 28, scale: 8
    end

    create unique_index(:open_interest, [:symbol, :time])

    execute(
      "SELECT create_hypertable('open_interest', 'time', chunk_time_interval => INTERVAL '7 days')"
    )

    # Long/Short Ratio hypertable
    create table(:long_short_ratio, primary_key: false) do
      add :symbol, :string, null: false, size: 32
      add :source, :string, null: false, size: 32
      add :time, :utc_datetime_usec, null: false
      add :long_ratio, :decimal, precision: 10, scale: 6
      add :short_ratio, :decimal, precision: 10, scale: 6
      add :ls_ratio, :decimal, precision: 10, scale: 6, null: false
    end

    create unique_index(:long_short_ratio, [:symbol, :source, :time])

    execute(
      "SELECT create_hypertable('long_short_ratio', 'time', chunk_time_interval => INTERVAL '7 days')"
    )

    # Funding rates hypertable
    create table(:funding_rates, primary_key: false) do
      add :symbol, :string, null: false, size: 32
      add :time, :utc_datetime_usec, null: false
      add :funding_rate, :decimal, precision: 12, scale: 8, null: false
      add :mark_price, :decimal, precision: 24, scale: 12
      add :index_price, :decimal, precision: 24, scale: 12
    end

    create unique_index(:funding_rates, [:symbol, :time])

    execute(
      "SELECT create_hypertable('funding_rates', 'time', chunk_time_interval => INTERVAL '30 days')"
    )

    # Liquidations hypertable
    create table(:liquidations, primary_key: false) do
      add :symbol, :string, null: false, size: 32
      add :time, :utc_datetime_usec, null: false
      add :side, :string, null: false, size: 8
      add :price, :decimal, precision: 24, scale: 12, null: false
      add :qty, :decimal, precision: 28, scale: 8, null: false
      add :order_type, :string, size: 16
      add :status, :string, size: 16
    end

    create index(:liquidations, [:symbol, :time])

    execute(
      "SELECT create_hypertable('liquidations', 'time', chunk_time_interval => INTERVAL '7 days')"
    )

    # CVD bars
    create table(:cvd_bars, primary_key: false) do
      add :symbol, :string, null: false, size: 32
      add :interval, :string, null: false, size: 8
      add :time, :utc_datetime_usec, null: false
      add :taker_buy_base, :decimal, precision: 28, scale: 8, null: false, default: 0
      add :taker_sell_base, :decimal, precision: 28, scale: 8, null: false, default: 0
      add :taker_buy_quote, :decimal, precision: 28, scale: 8, null: false, default: 0
      add :taker_sell_quote, :decimal, precision: 28, scale: 8, null: false, default: 0
      add :trades, :integer, null: false, default: 0
    end

    create unique_index(:cvd_bars, [:symbol, :interval, :time])

    execute(
      "SELECT create_hypertable('cvd_bars', 'time', chunk_time_interval => INTERVAL '7 days')"
    )
  end

  def down do
    drop table(:cvd_bars)
    drop table(:liquidations)
    drop table(:funding_rates)
    drop table(:long_short_ratio)
    drop table(:open_interest)
  end
end

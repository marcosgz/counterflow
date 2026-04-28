defmodule Counterflow.Repo.Migrations.Phase2SignalsAndWatchlist do
  use Ecto.Migration

  def up do
    create table(:watchlist, primary_key: false) do
      add :symbol, :string, primary_key: true, null: false, size: 32
      add :added_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :pinned, :boolean, null: false, default: false
      add :promoted_by, :string, size: 32
      add :promoted_score, :decimal, precision: 8, scale: 4
      add :last_active_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create table(:indicator_values, primary_key: false) do
      add :symbol, :string, null: false, size: 32
      add :interval, :string, null: false, size: 8
      add :indicator, :string, null: false, size: 32
      add :time, :utc_datetime_usec, null: false
      add :value, :map, null: false
    end

    create unique_index(:indicator_values, [:symbol, :interval, :indicator, :time])

    execute(
      "SELECT create_hypertable('indicator_values', 'time', chunk_time_interval => INTERVAL '7 days')"
    )

    create table(:signals, primary_key: false) do
      add :id, :string, null: false, size: 128
      add :symbol, :string, null: false, size: 32
      add :interval, :string, null: false, size: 8
      add :side, :string, null: false, size: 8
      add :score, :decimal, precision: 6, scale: 4, null: false
      add :components, :map, null: false
      add :price, :decimal, precision: 24, scale: 12, null: false
      add :leverage, :integer, null: false
      add :sl, :decimal, precision: 24, scale: 12
      add :tp1, :decimal, precision: 24, scale: 12
      add :tp2, :decimal, precision: 24, scale: 12
      add :ttl_minutes, :integer, null: false
      add :notes, {:array, :string}
      add :generated_at, :utc_datetime_usec, null: false
      add :outcome, :map
    end

    create unique_index(:signals, [:id, :generated_at])
    create index(:signals, [:symbol, :generated_at])

    execute(
      "SELECT create_hypertable('signals', 'generated_at', chunk_time_interval => INTERVAL '30 days')"
    )

    create table(:symbol_strategy_config, primary_key: false) do
      add :symbol, :string, primary_key: true, null: false, size: 32
      add :enabled, :boolean, null: false, default: true
      add :interval, :string, null: false, size: 8, default: "5m"
      add :weights, :map
      add :threshold, :decimal, precision: 4, scale: 3
      add :trend_profile, :integer, default: 2
      add :cooldown_minutes, :integer
      add :max_leverage, :integer, default: 5
      add :enable_alerts, :boolean, default: true
      add :enable_paper, :boolean, default: false
      add :enable_live, :boolean, default: false
    end
  end

  def down do
    drop table(:symbol_strategy_config)
    drop table(:signals)
    drop table(:indicator_values)
    drop table(:watchlist)
  end
end

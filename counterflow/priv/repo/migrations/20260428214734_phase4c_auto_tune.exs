defmodule Counterflow.Repo.Migrations.Phase4cAutoTune do
  use Ecto.Migration

  def change do
    alter table(:symbol_strategy_config) do
      add :auto_tune_enabled, :boolean, default: false, null: false
      add :last_auto_tune_at, :utc_datetime_usec
      add :last_auto_tune_summary, :map
    end

    create table(:auto_tune_runs) do
      add :symbol, :string, null: false, size: 32
      add :interval, :string, null: false, size: 8
      add :ran_at, :utc_datetime_usec, null: false
      add :previous_threshold, :decimal, precision: 4, scale: 3
      add :selected_threshold, :decimal, precision: 4, scale: 3
      add :evaluated, :map
      timestamps(type: :utc_datetime_usec)
    end

    create index(:auto_tune_runs, [:symbol, :ran_at])
  end
end

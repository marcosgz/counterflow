defmodule Counterflow.Repo.Migrations.Phase4bStrategyConfigExtras do
  use Ecto.Migration

  def change do
    alter table(:symbol_strategy_config) do
      add :min_tf_level, :integer, default: 0
      add :sides_enabled, :map, default: %{"long" => true, "short" => true}
    end
  end
end

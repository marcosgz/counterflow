defmodule Counterflow.Repo.Migrations.EnableTimescaledb do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS timescaledb")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS timescaledb")
  end
end

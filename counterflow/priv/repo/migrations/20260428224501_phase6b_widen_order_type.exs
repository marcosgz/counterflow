defmodule Counterflow.Repo.Migrations.Phase6bWidenOrderType do
  use Ecto.Migration

  # Original size 16 truncated "TAKE_PROFIT_MARKET" (18 chars). Widen.
  def up do
    execute("ALTER TABLE paper_orders ALTER COLUMN type TYPE varchar(32)")
    execute("ALTER TABLE live_orders ALTER COLUMN type TYPE varchar(32)")
  end

  def down do
    execute("ALTER TABLE paper_orders ALTER COLUMN type TYPE varchar(16)")
    execute("ALTER TABLE live_orders ALTER COLUMN type TYPE varchar(16)")
  end
end

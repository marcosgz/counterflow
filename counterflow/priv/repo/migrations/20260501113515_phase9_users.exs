defmodule Counterflow.Repo.Migrations.Phase9Users do
  use Ecto.Migration

  # Multi-tenant: every per-user table grows a user_id FK with on_delete:
  # delete_all so deleting a user wipes their data cleanly. Existing data
  # is dropped — the user explicitly authorized the destructive recreate.
  def change do
    create table(:users) do
      add :email, :string, null: false, size: 200
      add :password_hash, :string, null: false, size: 200
      add :is_admin, :boolean, default: false, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    execute "DROP TABLE IF EXISTS paper_fills CASCADE"
    execute "DROP TABLE IF EXISTS paper_positions CASCADE"
    execute "DROP TABLE IF EXISTS paper_funding_payments CASCADE"
    execute "DROP TABLE IF EXISTS paper_orders CASCADE"
    execute "DROP TABLE IF EXISTS paper_accounts CASCADE"
    execute "DROP TABLE IF EXISTS symbol_strategy_config CASCADE"
    execute "DROP TABLE IF EXISTS watchlist CASCADE"

    create table(:watchlist, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :symbol, :string, null: false, size: 32
      add :added_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :pinned, :boolean, null: false, default: false
      add :promoted_by, :string, size: 32
      add :promoted_score, :decimal, precision: 8, scale: 4
      add :last_active_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:watchlist, [:user_id, :symbol])

    create table(:symbol_strategy_config, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :symbol, :string, null: false, size: 32
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
      add :min_tf_level, :integer, default: 0
      add :sides_enabled, :map, default: %{"long" => true, "short" => true}
      add :auto_tune_enabled, :boolean, default: false, null: false
      add :last_auto_tune_at, :utc_datetime_usec
      add :last_auto_tune_summary, :map
    end

    create unique_index(:symbol_strategy_config, [:user_id, :symbol])

    create table(:paper_accounts, primary_key: false) do
      add :id, :string, primary_key: true, size: 64
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :initial_balance, :decimal, precision: 20, scale: 8, null: false
      add :balance, :decimal, precision: 20, scale: 8, null: false
      add :config, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:paper_accounts, [:user_id])

    create table(:paper_orders) do
      add :account_id, references(:paper_accounts, type: :string, on_delete: :delete_all), null: false
      add :client_id, :string, null: false
      add :symbol, :string, null: false, size: 32
      add :side, :string, null: false, size: 8
      add :type, :string, null: false, size: 32
      add :qty, :decimal, precision: 28, scale: 8, null: false
      add :price, :decimal, precision: 24, scale: 12
      add :stop_price, :decimal, precision: 24, scale: 12
      add :reduce_only, :boolean, default: false
      add :status, :string, null: false, size: 16
      add :signal_id, :string, size: 128
      add :placed_at, :utc_datetime_usec, null: false
      add :filled_at, :utc_datetime_usec
      add :filled_qty, :decimal, precision: 28, scale: 8, default: 0
      add :filled_avg, :decimal, precision: 24, scale: 12
      add :intent, :string, size: 24
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:paper_orders, [:account_id, :client_id])
    create index(:paper_orders, [:account_id, :symbol, :status])

    create table(:paper_fills) do
      add :order_id, references(:paper_orders, on_delete: :delete_all), null: false
      add :account_id, references(:paper_accounts, type: :string, on_delete: :delete_all), null: false
      add :symbol, :string, null: false, size: 32
      add :side, :string, null: false, size: 8
      add :price, :decimal, precision: 24, scale: 12, null: false
      add :qty, :decimal, precision: 28, scale: 8, null: false
      add :fee, :decimal, precision: 20, scale: 8, null: false, default: 0
      add :realized_pnl, :decimal, precision: 20, scale: 8
      add :filled_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:paper_fills, [:account_id, :symbol])

    create table(:paper_positions) do
      add :account_id, references(:paper_accounts, type: :string, on_delete: :delete_all), null: false
      add :symbol, :string, null: false, size: 32
      add :side, :string, null: false, size: 8
      add :qty, :decimal, precision: 28, scale: 8, null: false
      add :entry_avg, :decimal, precision: 24, scale: 12, null: false
      add :leverage, :integer, null: false
      add :opened_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :realized_pnl, :decimal, precision: 20, scale: 8, default: 0
      add :funding_paid, :decimal, precision: 20, scale: 8, default: 0
      add :signal_id, :string, size: 128
      timestamps(type: :utc_datetime_usec)
    end

    create index(:paper_positions, [:account_id, :symbol, :closed_at])
  end
end

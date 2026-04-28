defmodule Counterflow.Repo.Migrations.Phase6PaperTrading do
  use Ecto.Migration

  def change do
    create table(:paper_accounts, primary_key: false) do
      add :id, :string, primary_key: true, size: 64
      add :initial_balance, :decimal, precision: 20, scale: 8, null: false
      add :balance, :decimal, precision: 20, scale: 8, null: false
      add :config, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create table(:paper_orders) do
      add :account_id, references(:paper_accounts, type: :string), null: false
      add :client_id, :string, null: false
      add :symbol, :string, null: false, size: 32
      add :side, :string, null: false, size: 8
      add :type, :string, null: false, size: 16
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
      add :order_id, references(:paper_orders), null: false
      add :account_id, references(:paper_accounts, type: :string), null: false
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
      add :account_id, references(:paper_accounts, type: :string), null: false
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

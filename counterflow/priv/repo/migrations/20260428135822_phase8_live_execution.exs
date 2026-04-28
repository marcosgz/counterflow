defmodule Counterflow.Repo.Migrations.Phase8LiveExecution do
  use Ecto.Migration

  def change do
    create table(:live_orders) do
      add :account_id, :string, null: false, size: 64
      add :client_order_id, :string, null: false, size: 64
      add :binance_order_id, :bigint
      add :symbol, :string, null: false, size: 32
      add :side, :string, null: false, size: 8
      add :type, :string, null: false, size: 16
      add :qty, :decimal, precision: 28, scale: 8, null: false
      add :price, :decimal, precision: 24, scale: 12
      add :stop_price, :decimal, precision: 24, scale: 12
      add :reduce_only, :boolean, default: false
      add :status, :string, null: false, size: 16
      add :signal_id, :string, size: 128
      add :intent, :string, null: false, size: 24
      add :raw_request, :map, null: false
      add :raw_response, :map
      add :last_event_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:live_orders, [:client_order_id])
    create index(:live_orders, [:account_id, :symbol, :status])

    create table(:killswitch_events) do
      add :engaged_at, :utc_datetime_usec, null: false
      add :engaged_by, :string, null: false, size: 64
      add :reason, :text, null: false
      add :released_at, :utc_datetime_usec
      add :released_by, :string, size: 64
      timestamps(type: :utc_datetime_usec)
    end

    create table(:risk_rejections) do
      add :attempted_at, :utc_datetime_usec, null: false
      add :signal_id, :string, size: 128
      add :symbol, :string, size: 32
      add :side, :string, size: 8
      add :rejected_by, :string, null: false, size: 64
      add :details, :map
      timestamps(type: :utc_datetime_usec)
    end

    create index(:risk_rejections, [:rejected_by, :attempted_at])
  end
end

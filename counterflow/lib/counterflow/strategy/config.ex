defmodule Counterflow.Strategy.Config do
  @moduledoc """
  Per-symbol strategy configuration. Merges hard-coded defaults with the
  `symbol_strategy_config` row for the symbol.

  The Pipeline asks `for/2` once per closed candle to assemble the keyword
  list passed to `Strategy.Counterflow.evaluate/2`, plus the pre-eval
  filters (enabled?, sides_enabled, min_tf_level).
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Counterflow.Repo

  @primary_key false
  schema "symbol_strategy_config" do
    field :user_id, :integer, primary_key: true
    field :symbol, :string, primary_key: true
    field :enabled, :boolean, default: true
    field :interval, :string, default: "5m"
    field :weights, :map
    field :threshold, :decimal
    field :trend_profile, :integer, default: 2
    field :cooldown_minutes, :integer
    field :max_leverage, :integer, default: 5
    field :enable_alerts, :boolean, default: true
    field :enable_paper, :boolean, default: false
    field :enable_live, :boolean, default: false
    field :min_tf_level, :integer, default: 0
    field :sides_enabled, :map, default: %{"long" => true, "short" => true}
    field :auto_tune_enabled, :boolean, default: false
    field :last_auto_tune_at, :utc_datetime_usec
    field :last_auto_tune_summary, :map
  end

  @castable ~w(user_id symbol enabled interval weights threshold trend_profile
               cooldown_minutes max_leverage enable_alerts enable_paper
               enable_live min_tf_level sides_enabled auto_tune_enabled
               last_auto_tune_at last_auto_tune_summary)a

  def changeset(cfg, attrs) do
    cfg
    |> cast(attrs, @castable)
    |> validate_required([:user_id, :symbol])
    |> validate_inclusion(:trend_profile, 1..3)
    |> validate_number(:max_leverage, greater_than: 0, less_than_or_equal_to: 10)
  end

  @default %{
    enabled: true,
    interval: "5m",
    weights: nil,
    threshold: 0.55,
    trend_profile: 2,
    cooldown_minutes: nil,
    max_leverage: 5,
    enable_alerts: true,
    enable_paper: false,
    enable_live: false,
    min_tf_level: 0,
    sides_enabled: %{"long" => true, "short" => true},
    auto_tune_enabled: false,
    last_auto_tune_at: nil,
    last_auto_tune_summary: nil
  }

  @doc "Resolved config for a (symbol, interval) — defaults overridden by DB row."
  def for(symbol, interval \\ "5m", user_id \\ nil) do
    uid = user_id || Counterflow.Accounts.owner_id()

    base = Map.put(@default, :symbol, symbol) |> Map.put(:interval, interval)

    case uid && Repo.get_by(__MODULE__, user_id: uid, symbol: symbol) do
      %__MODULE__{} = row ->
        @default
        |> Map.merge(Map.from_struct(row) |> Map.drop([:__meta__]))
        |> Map.put(:symbol, symbol)

      _ ->
        base
    end
  end

  @doc "Upsert a per-symbol config from a plain map of attrs."
  def upsert(symbol, attrs, user_id \\ nil) do
    uid = user_id || Counterflow.Accounts.owner_id() || raise "no owner user; create one first"

    base =
      Repo.get_by(__MODULE__, user_id: uid, symbol: symbol) ||
        %__MODULE__{user_id: uid, symbol: symbol}

    base
    |> changeset(attrs |> Map.put(:user_id, uid) |> Map.put(:symbol, symbol))
    |> Repo.insert_or_update()
  end

  @doc "Convert resolved config to keyword list of strategy_opts for evaluate/2."
  def to_strategy_opts(cfg) do
    [
      threshold: decimal_to_float(cfg.threshold),
      weights: cfg.weights || nil
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  @doc """
  Returns `:proceed` if the (symbol, candle) pair passes per-config pre-checks,
  otherwise `{:skip, reason}` so the Pipeline can short-circuit before scoring.
  """
  def precheck(%__MODULE__{} = _cfg, _candle, _tf), do: :proceed

  def precheck(cfg, _candle, tf) when is_map(cfg) do
    cond do
      not cfg.enabled -> {:skip, :disabled}
      tf && is_integer(tf.level) && tf.level < cfg.min_tf_level -> {:skip, :tf_below_min}
      true -> :proceed
    end
  end

  defp decimal_to_float(nil), do: nil
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n / 1
end

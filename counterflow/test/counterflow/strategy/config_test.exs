defmodule Counterflow.Strategy.ConfigTest do
  use Counterflow.DataCase, async: false

  alias Counterflow.Strategy.Config

  test "for/2 returns defaults when no row exists" do
    cfg = Config.for("UNCONFIGURED")
    assert cfg.enabled == true
    assert cfg.threshold == 0.55
    assert cfg.trend_profile == 2
    assert cfg.min_tf_level == 0
    assert cfg.sides_enabled == %{"long" => true, "short" => true}
  end

  test "upsert/2 merges and round-trips" do
    {:ok, _} =
      Config.upsert("BTCUSDT", %{
        threshold: Decimal.new("0.4"),
        min_tf_level: 3,
        sides_enabled: %{"long" => true, "short" => false},
        trend_profile: 3
      })

    cfg = Config.for("BTCUSDT")
    assert Decimal.to_float(cfg.threshold) == 0.4
    assert cfg.min_tf_level == 3
    assert cfg.sides_enabled == %{"long" => true, "short" => false}
    assert cfg.trend_profile == 3
  end

  test "precheck/3 returns :skip when disabled" do
    cfg = %{enabled: false, min_tf_level: 0}
    assert {:skip, :disabled} = Config.precheck(cfg, nil, %{level: 5})
  end

  test "precheck/3 returns :skip when TF level below min" do
    cfg = %{enabled: true, min_tf_level: 3}
    assert {:skip, :tf_below_min} = Config.precheck(cfg, nil, %{level: 1})
  end

  test "precheck/3 returns :proceed when checks pass" do
    cfg = %{enabled: true, min_tf_level: 3}
    assert :proceed = Config.precheck(cfg, nil, %{level: 4})
  end

  test "to_strategy_opts/1 produces keyword list" do
    cfg = %{threshold: Decimal.new("0.6"), weights: nil}
    opts = Config.to_strategy_opts(cfg)
    assert Keyword.get(opts, :threshold) == 0.6
    refute Keyword.has_key?(opts, :weights)
  end
end

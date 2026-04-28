defmodule Counterflow.Strategy.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias Counterflow.Strategy.Diagnostics

  setup do
    Diagnostics.reset()
    :ok
  end

  test "record + lookup round-trip" do
    Diagnostics.record("BTCUSDT", "5m", %{reason: :emitted, score: 0.7, threshold: 0.55})
    row = Diagnostics.lookup("BTCUSDT", "5m")
    assert row.reason == :emitted
    assert row.score == 0.7
    assert row.threshold == 0.55
    assert %DateTime{} = row.evaluated_at
  end

  test "record overwrites prior row for same key" do
    Diagnostics.record("BTCUSDT", "5m", %{reason: :neutral, score: 0.0})
    Diagnostics.record("BTCUSDT", "5m", %{reason: :emitted, score: 0.8})
    assert Diagnostics.lookup("BTCUSDT", "5m").reason == :emitted
  end

  test "snapshot returns most-recent rows first" do
    Diagnostics.record("AAA", "5m", %{reason: :neutral, score: 0.1})
    Process.sleep(2)
    Diagnostics.record("BBB", "5m", %{reason: :emitted, score: 0.7})
    [first, second] = Diagnostics.snapshot()
    assert first.symbol == "BBB"
    assert second.symbol == "AAA"
  end

  test "snapshot is empty after reset" do
    Diagnostics.record("X", "1m", %{reason: :neutral})
    Diagnostics.reset()
    assert Diagnostics.snapshot() == []
  end
end

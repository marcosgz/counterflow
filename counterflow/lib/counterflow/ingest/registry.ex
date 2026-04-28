defmodule Counterflow.Ingest.Registry do
  @moduledoc "Registry for per-symbol ingest workers."

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def via(key), do: {:via, Registry, {__MODULE__, key}}
end

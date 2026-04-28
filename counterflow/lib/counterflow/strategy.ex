defmodule Counterflow.Strategy do
  @moduledoc """
  Strategy behaviour. Implementations consume a `Counterflow.Strategy.Input`
  and return either `:no_signal` or `{:signal, %Counterflow.Strategy.Signal{}}`.
  """

  @callback evaluate(Counterflow.Strategy.Input.t(), keyword()) ::
              :no_signal | {:signal, Counterflow.Strategy.Signal.t()}
end

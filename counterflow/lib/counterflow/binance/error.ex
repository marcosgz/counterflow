defmodule Counterflow.Binance.Error do
  @moduledoc "Tagged error from Binance API or transport."

  defexception [:status, :code, :message, :retryable, :raw]

  @type t :: %__MODULE__{
          status: integer() | nil,
          code: integer() | nil,
          message: String.t(),
          retryable: boolean(),
          raw: term()
        }

  @impl true
  def message(%__MODULE__{message: m, code: nil}), do: m
  def message(%__MODULE__{message: m, code: c}), do: "[#{c}] #{m}"
end

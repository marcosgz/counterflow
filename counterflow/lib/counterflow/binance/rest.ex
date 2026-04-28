defmodule Counterflow.Binance.Rest do
  @moduledoc """
  Thin REST wrapper for Binance USD-M Futures public endpoints.

  All functions return `{:ok, decoded}` on success or `{:error, %Counterflow.Binance.Error{}}`.
  """

  alias Counterflow.Binance.Error

  @base_url "https://fapi.binance.com"

  @spec klines(String.t(), String.t(), keyword()) :: {:ok, [list()]} | {:error, Error.t()}
  def klines(symbol, interval, opts \\ []) do
    params =
      [symbol: symbol, interval: interval]
      |> Keyword.merge(opts)

    request(:get, "/fapi/v1/klines", params: params)
  end

  @spec exchange_info() :: {:ok, map()} | {:error, Error.t()}
  def exchange_info do
    request(:get, "/fapi/v1/exchangeInfo", [])
  end

  @spec server_time() :: {:ok, integer()} | {:error, Error.t()}
  def server_time do
    case request(:get, "/fapi/v1/time", []) do
      {:ok, %{"serverTime" => t}} -> {:ok, t}
      other -> other
    end
  end

  defp request(method, path, opts) do
    url = base_url() <> path

    case Req.request(
           method: method,
           url: url,
           params: Keyword.get(opts, :params, []),
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        case maybe_decode(body) do
          %{"code" => code, "msg" => msg} ->
            {:error,
             %Error{
               status: status,
               code: code,
               message: msg,
               retryable: status >= 500 or code in [-1003, -1015],
               raw: body
             }}

          _ ->
            {:error,
             %Error{status: status, message: "non-200 response", retryable: status >= 500, raw: body}}
        end

      {:error, exc} ->
        {:error, %Error{message: Exception.message(exc), retryable: true, raw: exc}}
    end
  end

  defp base_url, do: Application.get_env(:counterflow, :binance_rest_base, @base_url)

  defp maybe_decode(body) when is_map(body), do: body
  defp maybe_decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end
  defp maybe_decode(body), do: body
end

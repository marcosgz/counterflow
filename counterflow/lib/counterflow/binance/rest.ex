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

  @spec open_interest_hist(String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def open_interest_hist(symbol, opts \\ []) do
    params = [
      symbol: symbol,
      period: Keyword.get(opts, :period, "5m"),
      limit: Keyword.get(opts, :limit, 30)
    ]

    request(:get, "/futures/data/openInterestHist", params: params)
  end

  @spec long_short_account_ratio(String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def long_short_account_ratio(symbol, opts \\ []) do
    params = [
      symbol: symbol,
      period: Keyword.get(opts, :period, "5m"),
      limit: Keyword.get(opts, :limit, 30)
    ]

    request(:get, "/futures/data/globalLongShortAccountRatio", params: params)
  end

  @spec top_long_short_position_ratio(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def top_long_short_position_ratio(symbol, opts \\ []) do
    params = [
      symbol: symbol,
      period: Keyword.get(opts, :period, "5m"),
      limit: Keyword.get(opts, :limit, 30)
    ]

    request(:get, "/futures/data/topLongShortPositionRatio", params: params)
  end

  @spec premium_index() :: {:ok, [map()]} | {:error, Error.t()}
  def premium_index, do: request(:get, "/fapi/v1/premiumIndex", [])

  @spec premium_index(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def premium_index(symbol), do: request(:get, "/fapi/v1/premiumIndex", params: [symbol: symbol])

  @spec ticker_24h() :: {:ok, [map()]} | {:error, Error.t()}
  def ticker_24h, do: request(:get, "/fapi/v1/ticker/24hr", [])

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
           retry: false,
           finch: Counterflow.Finch
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
             %Error{
               status: status,
               message: "non-200 response",
               retryable: status >= 500,
               raw: body
             }}
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

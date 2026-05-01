defmodule Counterflow.Binance.RestSigned do
  @moduledoc """
  HMAC-SHA256 signed REST client for Binance Futures private endpoints.

  Reads `BINANCE_API_KEY` + `BINANCE_API_SECRET` (or testnet variants)
  from env. Sign convention: every signed request gets a `timestamp`
  query param plus a `signature` derived as HMAC-SHA256 of the
  query-string (excluding signature) using the API secret.

  Targets:
    * production: https://fapi.binance.com (live trading — gated)
    * testnet:    https://testnet.binancefuture.com

  Selection via `:counterflow, :binance_market` config:
    * :live    → use BINANCE_API_KEY/SECRET against fapi.binance.com
    * :testnet → use BINANCE_TESTNET_API_KEY/SECRET against testnet
  """

  require Logger
  alias Counterflow.Binance.Error

  @live_base "https://fapi.binance.com"
  @testnet_base "https://testnet.binancefuture.com"
  @recv_window 5_000

  def post_signed(path, params \\ []), do: signed(:post, path, params)
  def get_signed(path, params \\ []), do: signed(:get, path, params)
  def delete_signed(path, params \\ []), do: signed(:delete, path, params)

  defp signed(method, path, params) do
    case credentials() do
      {:ok, key, secret} ->
        timestamp = System.system_time(:millisecond)

        params_with_meta =
          params
          |> Enum.into(%{})
          |> Map.put("timestamp", timestamp)
          |> Map.put("recvWindow", @recv_window)

        query = encode_query(params_with_meta)
        signature = sign(query, secret)
        full_query = query <> "&signature=" <> signature
        url = base() <> path <> "?" <> full_query

        Req.request(
          method: method,
          url: url,
          headers: [{"X-MBX-APIKEY", key}],
          finch: Counterflow.Finch,
          retry: false,
          receive_timeout: 15_000
        )
        |> handle()

      {:error, reason} ->
        {:error, %Error{message: "credentials missing: #{reason}", retryable: false}}
    end
  end

  defp handle({:ok, %{status: 200, body: body}}), do: {:ok, body}

  defp handle({:ok, %{status: status, body: %{"code" => code, "msg" => msg}}}) do
    {:error,
     %Error{status: status, code: code, message: msg, retryable: status >= 500 or code == -1003}}
  end

  defp handle({:ok, %{status: status, body: body}}),
    do: {:error, %Error{status: status, message: "non-200", retryable: status >= 500, raw: body}}

  defp handle({:error, exc}),
    do: {:error, %Error{message: Exception.message(exc), retryable: true, raw: exc}}

  @doc false
  def credentials do
    case market() do
      :live ->
        key = System.get_env("BINANCE_API_KEY")
        secret = System.get_env("BINANCE_API_SECRET")
        if key && secret, do: {:ok, key, secret}, else: {:error, :missing_live_keys}

      :testnet ->
        key = System.get_env("BINANCE_TESTNET_API_KEY")
        secret = System.get_env("BINANCE_TESTNET_API_SECRET")
        if key && secret, do: {:ok, key, secret}, else: {:error, :missing_testnet_keys}
    end
  end

  defp market, do: Application.get_env(:counterflow, :binance_market, :testnet)

  defp base do
    case market() do
      :live -> Application.get_env(:counterflow, :binance_live_base, @live_base)
      :testnet -> Application.get_env(:counterflow, :binance_testnet_base, @testnet_base)
    end
  end

  defp encode_query(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
  end

  @doc false
  def sign(query, secret) do
    :crypto.mac(:hmac, :sha256, secret, query)
    |> Base.encode16(case: :lower)
  end
end

defmodule Counterflow.LLM.Anthropic do
  @moduledoc "Anthropic (Claude) messages-API adapter."

  @behaviour Counterflow.LLM

  @default_model "claude-sonnet-4-6"
  @default_max_tokens 1500
  @base "https://api.anthropic.com"
  @anthropic_version "2023-06-01"

  @impl true
  def complete(prompt, opts \\ []) do
    with {:ok, %{api_key: key, model: model}} <- Counterflow.LLM.credentials() do
      messages = to_messages(prompt)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      system = Keyword.get(opts, :system)

      body =
        %{
          "model" => model || @default_model,
          "max_tokens" => max_tokens,
          "messages" => messages
        }
        |> maybe_add("system", system)

      url = base() <> "/v1/messages"

      case Req.post(url,
             json: body,
             headers: [
               {"x-api-key", key},
               {"anthropic-version", @anthropic_version},
               {"content-type", "application/json"}
             ],
             finch: Counterflow.Finch,
             retry: false,
             receive_timeout: 60_000
           ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, text}

        {:ok, %{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, exc} ->
          {:error, exc}
      end
    end
  end

  def configured? do
    case Counterflow.LLM.credentials() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp base, do: Application.get_env(:counterflow, :anthropic_base, @base)

  defp to_messages(prompt) when is_binary(prompt), do: [%{"role" => "user", "content" => prompt}]
  defp to_messages(list) when is_list(list), do: Enum.map(list, &normalize_msg/1)

  defp normalize_msg(%{role: r, content: c}), do: %{"role" => to_string(r), "content" => c}
  defp normalize_msg(%{"role" => _, "content" => _} = m), do: m

  defp maybe_add(map, _k, nil), do: map
  defp maybe_add(map, k, v), do: Map.put(map, k, v)
end

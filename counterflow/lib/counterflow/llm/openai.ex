defmodule Counterflow.LLM.OpenAI do
  @moduledoc "OpenAI chat-completions adapter."

  @behaviour Counterflow.LLM

  @default_model "gpt-4o-mini"
  @default_max_tokens 1500
  @base "https://api.openai.com"

  @impl true
  def complete(prompt, opts \\ []) do
    with {:ok, %{api_key: key, model: model}} <- Counterflow.LLM.credentials() do
      messages = to_messages(prompt, Keyword.get(opts, :system))
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

      body = %{
        "model" => model || @default_model,
        "max_tokens" => max_tokens,
        "messages" => messages
      }

      url = base() <> "/v1/chat/completions"

      case Req.post(url,
             json: body,
             headers: [
               {"authorization", "Bearer " <> key},
               {"content-type", "application/json"}
             ],
             finch: Counterflow.Finch,
             retry: false,
             receive_timeout: 60_000
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
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

  defp base, do: Application.get_env(:counterflow, :openai_base, @base)

  defp to_messages(prompt, nil) when is_binary(prompt), do: [%{"role" => "user", "content" => prompt}]

  defp to_messages(prompt, system) when is_binary(prompt) and is_binary(system) do
    [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => prompt}]
  end

  defp to_messages(list, nil) when is_list(list), do: Enum.map(list, &normalize_msg/1)

  defp to_messages(list, system) when is_list(list) and is_binary(system) do
    [%{"role" => "system", "content" => system} | Enum.map(list, &normalize_msg/1)]
  end

  defp normalize_msg(%{role: r, content: c}), do: %{"role" => to_string(r), "content" => c}
  defp normalize_msg(%{"role" => _, "content" => _} = m), do: m
end

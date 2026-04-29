defmodule Counterflow.LLM do
  @moduledoc """
  Provider-agnostic LLM adapter. Implementations hide the provider's auth,
  base URL, and request/response shape behind a single `complete/2`
  callback so the rest of Counterflow can treat any model the same way.

  Selection is via `:counterflow, :llm_provider` (atom) or the env var
  `COUNTERFLOW_LLM_PROVIDER` (one of "anthropic" | "openai" — extend by
  adding more adapter modules and updating `provider/0` below). API keys
  and model names live in `COUNTERFLOW_LLM_API_KEY` and
  `COUNTERFLOW_LLM_MODEL`.

  Built-in adapters:
    * `Counterflow.LLM.Anthropic` — Claude messages API
    * `Counterflow.LLM.OpenAI`    — OpenAI chat-completions API
  """

  @type opts :: keyword()
  @type prompt :: String.t() | [%{role: String.t(), content: String.t()}]

  @callback complete(prompt(), opts()) :: {:ok, String.t()} | {:error, term()}

  @spec complete(prompt(), opts()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
    case provider() do
      {:ok, mod} -> mod.complete(prompt, opts)
      {:error, _} = err -> err
    end
  end

  @spec configured?() :: boolean()
  def configured? do
    case provider() do
      {:ok, mod} -> mod.configured?()
      _ -> false
    end
  end

  @spec provider() :: {:ok, module()} | {:error, atom()}
  def provider do
    name =
      Application.get_env(:counterflow, :llm_provider) ||
        System.get_env("COUNTERFLOW_LLM_PROVIDER") ||
        "anthropic"

    case to_string(name) |> String.downcase() do
      "anthropic" -> {:ok, Counterflow.LLM.Anthropic}
      "claude" -> {:ok, Counterflow.LLM.Anthropic}
      "openai" -> {:ok, Counterflow.LLM.OpenAI}
      "gpt" -> {:ok, Counterflow.LLM.OpenAI}
      _ -> {:error, :unknown_provider}
    end
  end

  @doc "Provider name as a short label for UI display."
  def provider_label do
    case provider() do
      {:ok, Counterflow.LLM.Anthropic} -> "Anthropic Claude"
      {:ok, Counterflow.LLM.OpenAI} -> "OpenAI"
      _ -> "(none)"
    end
  end

  @doc false
  def credentials do
    cfg = Application.get_env(:counterflow, :llm, [])
    api_key = cfg[:api_key] || System.get_env("COUNTERFLOW_LLM_API_KEY")
    model = cfg[:model] || System.get_env("COUNTERFLOW_LLM_MODEL")

    cond do
      is_nil(api_key) or api_key == "" -> {:error, :missing_api_key}
      true -> {:ok, %{api_key: api_key, model: model}}
    end
  end
end

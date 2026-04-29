defmodule Counterflow.LLMTest do
  use ExUnit.Case, async: false

  alias Counterflow.LLM

  setup do
    bypass = Bypass.open()

    Application.put_env(:counterflow, :llm, api_key: "K", model: "test-model")
    Application.put_env(:counterflow, :anthropic_base, "http://localhost:#{bypass.port}")
    Application.put_env(:counterflow, :openai_base, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.delete_env(:counterflow, :llm)
      Application.delete_env(:counterflow, :anthropic_base)
      Application.delete_env(:counterflow, :openai_base)
      Application.delete_env(:counterflow, :llm_provider)
      System.delete_env("COUNTERFLOW_LLM_PROVIDER")
    end)

    {:ok, bypass: bypass}
  end

  test "provider/0 defaults to Anthropic" do
    Application.delete_env(:counterflow, :llm_provider)
    System.delete_env("COUNTERFLOW_LLM_PROVIDER")
    assert {:ok, Counterflow.LLM.Anthropic} = LLM.provider()
  end

  test "provider/0 honors :llm_provider config" do
    Application.put_env(:counterflow, :llm_provider, "openai")
    assert {:ok, Counterflow.LLM.OpenAI} = LLM.provider()
  end

  test "complete/2 routes to Anthropic adapter and returns text", %{bypass: bypass} do
    Application.put_env(:counterflow, :llm_provider, "anthropic")

    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      assert {"x-api-key", "K"} in conn.req_headers
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"content":[{"type":"text","text":"hello from claude"}]}))
    end)

    assert {:ok, "hello from claude"} = LLM.complete("hi")
  end

  test "complete/2 routes to OpenAI adapter and returns text", %{bypass: bypass} do
    Application.put_env(:counterflow, :llm_provider, "openai")

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      assert {"authorization", "Bearer K"} in conn.req_headers
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"choices":[{"message":{"content":"hello from gpt"}}]}))
    end)

    assert {:ok, "hello from gpt"} = LLM.complete("hi")
  end

  test "complete/2 returns :missing_api_key when not configured" do
    Application.delete_env(:counterflow, :llm)
    System.delete_env("COUNTERFLOW_LLM_API_KEY")
    Application.put_env(:counterflow, :llm_provider, "anthropic")

    assert {:error, :missing_api_key} = LLM.complete("hi")
  end
end

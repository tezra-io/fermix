defmodule FermixCore.Providers.AdapterTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Anthropic.Messages, as: AnthropicMessages
  alias FermixCore.Providers.OpenAI.ChatCompletions
  alias FermixCore.Providers.OpenAI.Codex
  alias FermixCore.Providers.OpenAI.Responses

  describe "for_route/1" do
    test "openai_codex provider routes to Codex regardless of model" do
      assert Adapter.for_route(%{
               provider: :openai_codex,
               model: "gpt-5",
               auth_mode: :oauth,
               base_url: "https://chatgpt.com/backend-api/codex"
             }) == Codex
    end

    test "openai + gpt model on api.openai.com routes to Responses" do
      assert Adapter.for_route(%{
               provider: :openai,
               model: "gpt-5.4-mini",
               auth_mode: :api_key,
               base_url: "https://api.openai.com/v1"
             }) == Responses
    end

    test "openai + o-series model on api.openai.com routes to Responses" do
      assert Adapter.for_route(%{
               provider: :openai,
               model: "o4-mini",
               auth_mode: :api_key,
               base_url: "https://api.openai.com/v1"
             }) == Responses
    end

    test "openai + gpt model on a non-openai base url routes to ChatCompletions" do
      assert Adapter.for_route(%{
               provider: :openai,
               model: "gpt-5.4-mini",
               auth_mode: :api_key,
               base_url: "https://openrouter.ai/api/v1"
             }) == ChatCompletions
    end

    test "openai + non-eligible model on api.openai.com routes to ChatCompletions" do
      assert Adapter.for_route(%{
               provider: :openai,
               model: "babbage-002",
               auth_mode: :api_key,
               base_url: "https://api.openai.com/v1"
             }) == ChatCompletions
    end

    test "anthropic provider routes to Messages" do
      assert Adapter.for_route(%{
               provider: :anthropic,
               model: "claude-4-5-sonnet",
               auth_mode: :api_key,
               base_url: "https://api.anthropic.com"
             }) == AnthropicMessages
    end

    test "xai provider routes to XAI.Responses" do
      assert Adapter.for_route(%{
               provider: :xai,
               model: "grok-4.3",
               auth_mode: :api_key,
               base_url: "https://api.x.ai/v1"
             }) == FermixCore.Providers.XAI.Responses
    end

    test "ollama routes to ChatCompletions via its descriptor (keyless)" do
      assert Adapter.for_route(%{
               provider: :ollama,
               model: "qwen3:32b",
               auth_mode: :none,
               base_url: "http://localhost:11434/v1"
             }) == ChatCompletions
    end

    test "openrouter routes to ChatCompletions via its descriptor" do
      assert Adapter.for_route(%{
               provider: :openrouter,
               model: "anthropic/claude-sonnet-4.6",
               auth_mode: :api_key,
               base_url: "https://openrouter.ai/api/v1"
             }) == ChatCompletions
    end

    # together/groq were accepted-but-unroutable escape hatches (no resolver
    # ever existed); M12 §2.3-8 removed the dead dispatch clause.
    for provider <- [:together, :groq] do
      test "#{provider} no longer has an adapter escape hatch" do
        assert_raise ArgumentError, ~r/no adapter for/, fn ->
          Adapter.for_route(%{
            provider: unquote(provider),
            model: "any-model",
            auth_mode: :api_key,
            base_url: "https://example.test/v1"
          })
        end
      end
    end

    test "raises ArgumentError when no adapter matches" do
      assert_raise ArgumentError, ~r/no adapter for/, fn ->
        Adapter.for_route(%{
          provider: :unknown,
          model: "x",
          auth_mode: :api_key,
          base_url: "https://example.test"
        })
      end
    end
  end
end

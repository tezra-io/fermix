defmodule FermixCore.Providers.RouteResolverTest do
  use ExUnit.Case, async: false

  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Anthropic.Messages, as: AnthropicMessages
  alias FermixCore.Providers.OpenAI.ChatCompletions
  alias FermixCore.Providers.OpenAI.Codex
  alias FermixCore.Providers.OpenAI.Responses
  alias FermixCore.Providers.RouteResolver

  describe "resolve!/1" do
    test "nil provider falls back to OpenAI Chat Completions when api_key + non-eligible model" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: nil,
          model: "babbage-002",
          api_key: "sk-test",
          base_url: "https://api.openai.com/v1",
          auth_mode: :api_key
        )

      assert route_key.provider == :openai
      assert route_key.model == "babbage-002"
      assert opts[:model] == "babbage-002"
      assert opts[:api_key] == "sk-test"
      assert Adapter.for_route(route_key) == ChatCompletions
    end

    test ":openai_codex provider forces oauth and routes to Codex" do
      {route_key, _opts} =
        RouteResolver.resolve!(
          provider: :openai_codex,
          model: "gpt-5",
          base_url: "https://chatgpt.com/backend-api/codex/responses"
        )

      assert route_key.provider == :openai_codex
      assert route_key.auth_mode == :oauth
      assert Adapter.for_route(route_key) == Codex
    end

    test ":openai_codex defaults to gpt-5.5 when no model is configured" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: :openai_codex,
          access_token: "tok"
        )

      assert route_key.model == "gpt-5.5"
      assert opts[:model] == "gpt-5.5"
    end

    test ":openai rejects auth_mode :oauth; Codex OAuth is a separate provider" do
      assert_raise ArgumentError, ~r/use provider: :openai_codex/, fn ->
        RouteResolver.resolve!(
          provider: :openai,
          model: "gpt-4o",
          auth_mode: :oauth,
          access_token: "oauth-bearer-token",
          base_url: "https://api.openai.com/v1"
        )
      end
    end

    test "default OpenAI rejects auth_mode :oauth" do
      assert_raise ArgumentError, ~r/use provider: :openai_codex/, fn ->
        RouteResolver.resolve!(
          model: "gpt-4o",
          auth_mode: :oauth,
          access_token: "tok",
          base_url: "https://api.openai.com/v1"
        )
      end
    end

    test ":openai with eligible model on api.openai.com routes to Responses" do
      {route_key, _opts} =
        RouteResolver.resolve!(
          provider: :openai,
          model: "gpt-4o",
          api_key: "sk-test",
          base_url: "https://api.openai.com/v1",
          auth_mode: :api_key
        )

      assert Adapter.for_route(route_key) == Responses
    end

    test ":anthropic produces an Anthropic route_key with sane defaults" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: :anthropic,
          api_key: "sk-ant-test"
        )

      assert route_key.provider == :anthropic
      assert route_key.auth_mode == :api_key
      assert route_key.base_url == "https://api.anthropic.com/v1"
      assert is_binary(route_key.model) and route_key.model != ""

      assert opts[:api_key] == "sk-ant-test"
      assert opts[:base_url] == "https://api.anthropic.com/v1"

      assert Adapter.for_route(route_key) == AnthropicMessages
    end

    test ":anthropic respects explicit model and base_url" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: :anthropic,
          model: "claude-opus-4-7",
          base_url: "https://anthropic.example/v1"
        )

      assert route_key.model == "claude-opus-4-7"
      assert route_key.base_url == "https://anthropic.example/v1"
      assert opts[:model] == "claude-opus-4-7"
      assert opts[:base_url] == "https://anthropic.example/v1"
    end

    test "unknown provider raises ArgumentError" do
      assert_raise ArgumentError, ~r/no resolver for provider/, fn ->
        RouteResolver.resolve!(provider: :mystery)
      end
    end

    test "configured provider in :fermix_core, :agent is used when opts omit it" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :agent, provider: :openai_codex)
        Application.put_env(:fermix_core, :providers, openai: [])

        # Opts omit :provider — must pick up :openai_codex from agent app env.
        {route_key, _opts} =
          RouteResolver.resolve!(model: "gpt-5", access_token: "tok")

        assert route_key.provider == :openai_codex
        assert Adapter.for_route(route_key) == Codex
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "explicit opts :provider overrides configured provider" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :agent, provider: :openai_codex)
        Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])

        {route_key, _opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-4o",
            api_key: "sk-test",
            base_url: "https://api.openai.com/v1"
          )

        assert route_key.provider == :openai
        assert Adapter.for_route(route_key) == Responses
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "old c4f02a4 schema location is ignored (provider must live under :agent)" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        # Old layout: provider under [:providers, :openai] (the c4f02a4 hotpatch shape).
        # The dispatcher must NOT pick it up from there.
        Application.put_env(:fermix_core, :agent, [])

        Application.put_env(:fermix_core, :providers,
          openai: [provider: :openai_codex, auth_mode: :api_key, api_key: "sk-test"]
        )

        {route_key, _opts} =
          RouteResolver.resolve!(model: "gpt-4o")

        # Falls through to :openai (the default), NOT :openai_codex.
        assert route_key.provider == :openai
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "reasoning_effort from opts overrides the per-provider config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test", reasoning_effort: :low]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1",
            reasoning_effort: :high
          )

        assert opts[:reasoning_effort] == :high
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "reasoning_effort falls through to the per-provider config block when opts omit it" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test", reasoning_effort: :medium]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1"
          )

        assert opts[:reasoning_effort] == :medium
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "reasoning_effort is omitted from adapter_opts when neither opts nor config set it" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test"]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1"
          )

        refute Keyword.has_key?(opts, :reasoning_effort)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "raises ArgumentError when reasoning_effort in config is invalid (boundary validation)" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test", reasoning_effort: :absurd]
        )

        assert_raise ArgumentError, ~r/invalid reasoning_effort: :absurd/, fn ->
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1"
          )
        end
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "Codex resolver reads reasoning_effort from the openai_codex config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [reasoning_effort: :xhigh]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5")

        assert opts[:reasoning_effort] == :xhigh
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "Codex resolver does not expose a store override because Codex requires store=false" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [store: true]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5")

        refute Keyword.has_key?(opts, :store)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end
  end
end

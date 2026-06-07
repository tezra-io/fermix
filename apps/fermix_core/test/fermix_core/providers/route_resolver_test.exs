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

    test ":anthropic sources api_key, default_model, and base_url from the provider config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [
            api_key: "sk-ant-config",
            default_model: "claude-haiku-4-5",
            base_url: "https://anthropic-proxy.example/v1"
          ]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :anthropic)

        assert route_key.model == "claude-haiku-4-5"
        assert route_key.base_url == "https://anthropic-proxy.example/v1"
        assert opts[:api_key] == "sk-ant-config"
        assert opts[:model] == "claude-haiku-4-5"
        assert opts[:base_url] == "https://anthropic-proxy.example/v1"
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic explicit opts override the provider config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [api_key: "sk-ant-config", default_model: "claude-haiku-4-5"]
        )

        {route_key, opts} =
          RouteResolver.resolve!(
            provider: :anthropic,
            model: "claude-sonnet-4-6",
            api_key: "sk-ant-explicit"
          )

        assert route_key.model == "claude-sonnet-4-6"
        assert opts[:api_key] == "sk-ant-explicit"
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic auth_mode :oauth produces an oauth route bound to the anthropic_oauth profile" do
      {route_key, opts} = RouteResolver.resolve!(provider: :anthropic, auth_mode: :oauth)

      assert route_key.auth_mode == :oauth
      assert route_key.base_url == "https://api.anthropic.com/v1"
      assert opts[:auth_profile] == "anthropic_oauth"
      assert opts[:token_server] == FermixCore.Auth.TokenSupervisor
      refute Keyword.has_key?(opts, :api_key)
    end

    test ":anthropic auth_mode from the config block selects oauth and drops the configured api_key" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [auth_mode: "oauth", api_key: "sk-ant-config"]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :anthropic)

        assert route_key.auth_mode == :oauth
        assert opts[:auth_profile] == "anthropic_oauth"
        refute Keyword.has_key?(opts, :api_key)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic explicit access_token flows into the oauth route" do
      {_route_key, opts} =
        RouteResolver.resolve!(provider: :anthropic, auth_mode: :oauth, access_token: "tok")

      assert opts[:access_token] == "tok"
    end

    test ":anthropic api_key mode never carries oauth artifacts (billing-flip guard)" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        # No api_key configured at all — the route must NOT degrade into
        # oauth or sneak any credential in from another source.
        Application.put_env(:fermix_core, :providers, anthropic: [auth_mode: "api_key"])

        {route_key, opts} = RouteResolver.resolve!(provider: :anthropic)

        assert route_key.auth_mode == :api_key
        refute Keyword.has_key?(opts, :auth_profile)
        refute Keyword.has_key?(opts, :access_token)
        refute Keyword.has_key?(opts, :token_server)
        refute Keyword.has_key?(opts, :api_key)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic rejects an unknown auth_mode" do
      assert_raise ArgumentError, ~r/auth_mode/, fn ->
        RouteResolver.resolve!(provider: :anthropic, auth_mode: :strange)
      end
    end

    test ":xai produces an xAI route_key with sane defaults" do
      {route_key, opts} = RouteResolver.resolve!(provider: :xai, api_key: "xai-key")

      assert route_key.provider == :xai
      assert route_key.auth_mode == :api_key
      assert route_key.base_url == "https://api.x.ai/v1"
      assert is_binary(route_key.model) and route_key.model != ""

      assert opts[:api_key] == "xai-key"
      assert Adapter.for_route(route_key) == FermixCore.Providers.XAI.Responses
    end

    test ":xai sources api_key, default_model, base_url, and effort from the config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          xai: [
            api_key: "xai-config",
            default_model: "grok-code-fast-1",
            base_url: "https://xai-proxy.example/v1",
            reasoning_effort: :high
          ]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :xai)

        assert route_key.model == "grok-code-fast-1"
        assert route_key.base_url == "https://xai-proxy.example/v1"
        assert opts[:api_key] == "xai-config"
        assert opts[:reasoning_effort] == :high
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":xai auth_mode :oauth produces an oauth route bound to the xai_oauth profile" do
      {route_key, opts} =
        RouteResolver.resolve!(provider: :xai, auth_mode: :oauth, reasoning_effort: :low)

      assert route_key.auth_mode == :oauth
      assert opts[:auth_profile] == "xai_oauth"
      assert opts[:token_server] == FermixCore.Auth.TokenSupervisor
      assert opts[:reasoning_effort] == :low
      refute Keyword.has_key?(opts, :api_key)
    end

    test "unknown provider raises ArgumentError" do
      assert_raise ArgumentError, ~r/no resolver for provider/, fn ->
        RouteResolver.resolve!(provider: :mystery)
      end
    end

    test "switching the configured provider re-resolves the next route (§2.1)" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [api_key: "sk-ant"],
          xai: [api_key: "xai-key"]
        )

        Application.put_env(:fermix_core, :agent, provider: :anthropic)
        {route_key, _opts} = RouteResolver.resolve!()
        assert route_key.provider == :anthropic
        assert Adapter.for_route(route_key) == AnthropicMessages

        # Setup flips the active provider — the very next resolution must
        # follow, with no stale route or adapter reuse.
        Application.put_env(:fermix_core, :agent, provider: :xai)
        {route_key, opts} = RouteResolver.resolve!()
        assert route_key.provider == :xai
        assert opts[:api_key] == "xai-key"
        assert Adapter.for_route(route_key) == FermixCore.Providers.XAI.Responses
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
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

    test "Codex resolver reads fast mode from the openai_codex config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [fast: true]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5")

        assert opts[:fast] == true
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "explicit Codex fast mode overrides the openai_codex config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [fast: true]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5", fast: false)

        assert opts[:fast] == false
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

  describe "primary flag selection" do
    setup do
      providers = Application.get_env(:fermix_core, :providers, [])
      agent = Application.get_env(:fermix_core, :agent, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :providers, providers)
        Application.put_env(:fermix_core, :agent, agent)
      end)

      :ok
    end

    test "resolve!() honors a provider block primary flag over the legacy agent provider" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-x"],
        anthropic: [primary: true, api_key: "sk-ant"]
      )

      Application.put_env(:fermix_core, :agent, provider: :openai)

      {route_key, _opts} = RouteResolver.resolve!()

      assert route_key.provider == :anthropic
    end

    test "resolve!() fails loud when more than one provider is primary" do
      Application.put_env(:fermix_core, :providers,
        openai: [primary: true, api_key: "sk-x"],
        xai: [primary: true, api_key: "xai-key"]
      )

      Application.put_env(:fermix_core, :agent, [])

      assert_raise ArgumentError, ~r/exactly one provider/, fn ->
        RouteResolver.resolve!()
      end
    end
  end
end
